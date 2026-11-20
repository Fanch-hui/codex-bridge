import BridgeACP
import BridgeAgentCore
import BridgeProviderRuntime
import BridgeSecurity
import Foundation

extension ServiceCommunityProviders {
  func sharedHost() async throws -> ProviderHostClient {
    if let host { return host }
    if let starting { return try await starting.value }
    let task = Task { try await self.launchSharedHost() }
    starting = task
    do {
      let client = try await task.value
      host = client
      starting = nil
      return client
    } catch {
      starting = nil
      throw error
    }
  }

  private func launchSharedHost() async throws -> ProviderHostClient {
    let current = try await records().filter(\.isInstalled)
    guard !current.isEmpty else { throw ServiceCommunityProviderError.pluginMissing }
    let (resources, installer) = try await runtime()
    let (client, loaded) = try await Self.launch(
      plugins: current, resources: resources, directory: directory,
      installer: installer, secrets: secrets, fallback: nil)
    do {
      for record in current {
        let ids = try Self.providerIDs(in: loaded, for: record, secrets: secrets)
        guard Set(ids) == Set(record.providers) else {
          throw ServiceCommunityProviderError.incompatible("供应商声明已变化，请重新安装插件。")
        }
      }
      return client
    } catch {
      guard await client.close() else { throw ServiceCommunityProviderError.stopped }
      throw error
    }
  }

  func probe(_ plugin: Plugin) async throws -> [String] {
    guard let id = UUID(uuidString: plugin.id) else {
      throw ServiceCommunityProviderError.invalidRequest
    }
    let (resources, installer) = try await runtime()
    let (client, loaded) = try await Self.launch(
      plugins: [plugin], resources: resources, directory: directory,
      installer: installer, secrets: secrets, fallback: id)
    do {
      let ids = try Self.providerIDs(in: loaded, for: plugin, secrets: secrets)
      guard await client.close() else { throw ServiceCommunityProviderError.stopped }
      return ids
    } catch {
      guard await client.close() else { throw ServiceCommunityProviderError.stopped }
      throw error
    }
  }

  static func launch(
    plugins: [Plugin], resources: ProviderRuntimeResources, directory: URL,
    installer: CommunityProviderInstallation, secrets: any SecretStore, fallback: UUID?
  ) async throws -> (ProviderHostClient, ACPJSONValue) {
    let bun = try await installer.prepareBun()
    try resources.validateEntrypoints()
    var owners: [String: UUID] = [:]
    for plugin in plugins {
      guard let id = UUID(uuidString: plugin.id) else {
        throw ServiceCommunityProviderError.invalidStoredConfiguration
      }
      for provider in plugin.providers {
        guard owners.updateValue(id, forKey: provider) == nil else {
          throw ServiceCommunityProviderError.conflictingProvider(provider)
        }
      }
    }
    let router = ServiceCommunitySecrets(store: secrets, owners: owners, fallback: fallback)
    let configuration = ACPProcessTransportConfiguration(
      argv: [bun.path, resources.communityEntry.path], workingDirectory: directory.path,
      environment: hostEnvironment(directory), maximumFrameBytes: 16 * 1_024 * 1_024,
      maximumStandardErrorBytes: 64 * 1_024, maximumLifetime: .seconds(24 * 60 * 60))
    let client = ProviderHostClient(
      transport: try ACPProcessTransport.launch(configuration: configuration),
      secretHandler: { try await router.handle($0) })
    await client.start()
    let list: [ACPJSONValue] = plugins.map {
      .object(["spec": .string("\($0.package)@\($0.version)"), "target": .string($0.target)])
    }
    do {
      let response = try await client.request(
        method: "init",
        params: .object(["directory": .string(directory.path), "plugins": .array(list)]))
      return (client, response)
    } catch {
      guard await client.close() else { throw ServiceCommunityProviderError.stopped }
      throw error
    }
  }

  static func providerIDs(in response: ACPJSONValue, for plugin: Plugin, secrets: any SecretStore)
    throws -> [String]
  {
    let spec = "\(plugin.package)@\(plugin.version)"
    guard
      let entry = response["plugins"]?.arrayValue?.first(where: { $0["spec"]?.stringValue == spec })
    else {
      throw ServiceCommunityProviderError.incompatible("宿主未返回插件状态。")
    }
    if let message = entry["error"]?.stringValue {
      throw ServiceCommunityProviderError.incompatible(
        OutboundContentSecurity.redactedSecrets(message, maximumUTF8Bytes: 2048))
    }
    guard let values = entry["provides"]?.arrayValue, !values.isEmpty else {
      throw ServiceCommunityProviderError.incompatible("插件没有提供受支持的供应商认证接口。")
    }
    let ids = values.compactMap(\.stringValue)
    guard ids.count == values.count, Set(ids).count == ids.count else {
      throw ServiceCommunityProviderError.incompatible("供应商标识无效。")
    }
    for id in ids {
      _ = try ProviderSecretStore(store: secrets, installationID: UUID(), providers: [id])
    }
    return ids
  }

  func stopHost() async throws {
    idle?.cancel()
    idle = nil
    guard let client = host else { return }
    guard await client.close() else { throw ServiceCommunityProviderError.stopped }
    host = nil
  }

  func request(
    _ client: ProviderHostClient, method: String, params: ACPJSONValue,
    timeout: Duration = .seconds(60), stream: ProviderHostClient.StreamHandler? = nil
  ) async throws -> ACPJSONValue {
    do {
      return try await client.request(
        method: method, params: params, timeout: timeout, stream: stream)
    } catch {
      if await client.isClosed, host === client {
        guard await client.close() else { throw ServiceCommunityProviderError.stopped }
        if host === client {
          host = nil
          authorizations.removeAll()
        }
      }
      throw error
    }
  }

  func scheduleIdle() {
    idle?.cancel()
    guard active == 0, !changing, !shuttingDown, host != nil else { return }
    idle = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(300)) } catch { return }
      await self?.expireIdleHost()
    }
  }

  func expireIdleHost() async {
    guard active == 0, !changing else { return }
    authorizations = authorizations.filter { $0.value.expires > Date() }
    if !authorizations.isEmpty {
      scheduleIdle()
      return
    }
    changing = true
    defer {
      changing = false
      notifyDrained()
    }
    do { try await stopHost() } catch {
      for plugin in plugins ?? [] { runtimeErrors[plugin.id] = "社区供应商宿主未能退出。" }
    }
  }

  static func hostEnvironment(
    _ directory: URL,
    inherited: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    let resolvedHome: String = {
      if let home = try? AgentProviderEnvironment.homeDirectory(source: inherited), !home.isEmpty {
        return home
      }
      let fallback = FileManager.default.homeDirectoryForCurrentUser.path
      return fallback.isEmpty ? directory.path : fallback
    }()
    let tempDirectory = validTempDirectory(from: inherited) ?? directory.path
    var environment: [String: String] = [
      "HOME": resolvedHome, "USERPROFILE": resolvedHome,
      "TMPDIR": tempDirectory, "TEMP": tempDirectory, "TMP": tempDirectory,
    ]
    #if os(Windows)
      AgentProviderEnvironment.applyWindowsSystemEnvironment(to: &environment, from: inherited)
      environment["USERPROFILE"] = resolvedHome
      environment["PATH"] = buildWindowsHostPath(
        home: resolvedHome, inherited: inherited, environment: environment)
    #else
      environment["PATH"] = buildPOSIXHostPath(home: resolvedHome, inherited: inherited)
      let posixDesktopKeys = [
        "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME",
        "LANG", "LC_ALL", "USER", "LOGNAME",
        "DISPLAY", "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS",
      ]
      copyValidEnvironmentKeys(posixDesktopKeys, from: inherited, into: &environment)
    #endif
    let toolConfigKeys = [
      "AWS_PROFILE", "AWS_DEFAULT_PROFILE", "AWS_REGION", "AWS_DEFAULT_REGION",
      "AWS_CONFIG_FILE", "AWS_SHARED_CREDENTIALS_FILE", "AWS_SDK_LOAD_CONFIG", "AWS_CA_BUNDLE",
      "MAGPIE_BEDROCK_AWS_CLI",
      "GROK_BIN_DIR", "GROK_HOME",
      "TELEAGENT_APP_PATH", "TELEAGENT_DATA", "TELEAGENT_CONFIG",
    ]
    copyValidEnvironmentKeys(toolConfigKeys, from: inherited, into: &environment)
    for key in ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY"] {
      if let value = firstValidValue(
        ["MAGPIE_\(key)", "MAGPIE_\(key.lowercased())", key, key.lowercased()], from: inherited)
      {
        environment["MAGPIE_\(key)"] = value
      }
    }
    return environment
  }

  private static func validTempDirectory(from inherited: [String: String]) -> String? {
    #if os(Windows)
      let keys = ["TEMP", "TMP", "TMPDIR"]
    #else
      let keys = ["TMPDIR", "TEMP", "TMP"]
    #endif
    guard let value = firstValidValue(keys, from: inherited),
      AgentPathSemantics.isAbsolute(value, style: .current)
    else { return nil }
    return value
  }

  private static func buildPOSIXHostPath(home: String, inherited: [String: String]) -> String {
    let source = AgentPathSemantics.splitPathList(inherited["PATH"] ?? "", style: .posix)
      .filter { isValidEnvValue($0) && AgentPathSemantics.isAbsolute($0, style: .posix) }
    let extras = [
      "\(home)/.grok/bin", "\(home)/.local/bin", "\(home)/.bun/bin", "\(home)/.cargo/bin",
      "\(home)/.npm-global/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin",
      "/usr/local/bin", "/usr/local/sbin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]
    var seen = Set<String>()
    let unique = (source + extras).filter { seen.insert($0).inserted }
    return AgentPathSemantics.joinPathList(unique, style: .posix)
  }

  private static func buildWindowsHostPath(
    home: String, inherited: [String: String], environment: [String: String]
  ) -> String {
    let rawPath = lookupCaseInsensitive("PATH", in: inherited) ?? ""
    let source = AgentPathSemantics.splitPathList(rawPath, style: .windows)
      .filter { isValidEnvValue($0) && AgentPathSemantics.isAbsolute($0, style: .windows) }
    var extras = ["\(home)\\.grok\\bin", "\(home)\\.local\\bin", "\(home)\\.bun\\bin"]
    if let appData = environment["APPDATA"], !appData.isEmpty {
      extras.append("\(appData)\\npm")
    }
    if let localAppData = environment["LOCALAPPDATA"], !localAppData.isEmpty {
      extras.append("\(localAppData)\\Programs")
    }
    if let windows = environment["SystemRoot"] ?? environment["WINDIR"], !windows.isEmpty {
      extras.append("\(windows)\\System32")
      extras.append(windows)
    }
    var seen = Set<String>()
    let unique = (source + extras).filter { candidate in
      let key =
        AgentPathSemantics.canonicalPath(candidate, style: .windows)?.lowercased()
        ?? candidate.lowercased()
      return seen.insert(key).inserted
    }
    return AgentPathSemantics.joinPathList(unique, style: .windows)
  }

  private static func copyValidEnvironmentKeys(
    _ keys: [String], from source: [String: String], into target: inout [String: String]
  ) {
    for key in keys {
      if let value = firstValidValue([key], from: source) { target[key] = value }
    }
  }

  private static func firstValidValue(_ keys: [String], from source: [String: String]) -> String? {
    for key in keys {
      #if os(Windows)
        let candidate = lookupCaseInsensitive(key, in: source)
      #else
        let candidate = source[key]
      #endif
      if let candidate, isValidEnvValue(candidate) { return candidate }
    }
    return nil
  }

  private static func lookupCaseInsensitive(_ name: String, in source: [String: String]) -> String?
  {
    if let exact = source[name] { return exact }
    guard
      let matched = source.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
    else { return nil }
    return source[matched]
  }

  private static func isValidEnvValue(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 16 * 1_024 && !value.contains("\0")
      && value.rangeOfCharacter(from: .controlCharacters) == nil
  }
}

private actor ServiceCommunitySecrets {
  let store: any SecretStore
  let owners: [String: UUID]
  let fallback: UUID?
  var stores: [String: ProviderSecretStore] = [:]

  init(store: any SecretStore, owners: [String: UUID], fallback: UUID?) {
    self.store = store
    self.owners = owners
    self.fallback = fallback
  }

  func handle(_ params: ACPJSONValue) async throws -> ACPJSONValue {
    guard let provider = params["provider"]?.stringValue, let id = owners[provider] ?? fallback
    else {
      throw ProviderRuntimeError.invalidMessage
    }
    let scoped: ProviderSecretStore
    if let existing = stores[provider] {
      scoped = existing
    } else {
      scoped = try ProviderSecretStore(store: store, installationID: id, providers: [provider])
      stores[provider] = scoped
    }
    return try await scoped.handle(params)
  }
}
