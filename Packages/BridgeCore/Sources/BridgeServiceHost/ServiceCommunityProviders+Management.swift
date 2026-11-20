import BridgeACP
import BridgeProviderRuntime
import BridgeSecurity
import Foundation

extension ServiceCommunityProviders {
  func change(action: String, payload: ACPJSONValue) async throws -> ACPJSONValue {
    authorizations = authorizations.filter { $0.value.expires > Date() }
    guard !shuttingDown, !changing, active == 0, authorizations.isEmpty else {
      throw ServiceCommunityProviderError.busy
    }
    changing = true
    idle?.cancel()
    defer {
      changing = false
      notifyDrained()
      scheduleIdle()
    }
    if action == "install" {
      guard let name = payload["package"]?.stringValue,
        let version = payload["version"]?.stringValue
      else {
        throw ServiceCommunityProviderError.invalidRequest
      }
      let operationID = payload["operationID"]?.stringValue ?? UUID().uuidString.lowercased()
      guard !operationID.isEmpty, operationID.utf8.count <= 128 else {
        throw ServiceCommunityProviderError.invalidRequest
      }
      installationOperation = InstallationOperation(
        operationID: operationID, package: name, version: version)
      do {
        var current = try await records()
        let existing = current.firstIndex(where: { $0.package == name })
        guard existing.map({ !current[$0].isInstalled }) ?? true else {
          throw ServiceCommunityProviderError.duplicatePlugin
        }
        guard current.filter(\.isInstalled).count < 64, existing != nil || current.count < 256
        else {
          throw ServiceCommunityProviderError.busy
        }
        try await stopHost()
        let (_, installer) = try await runtime()
        installationOperation?.phase = "installing"
        let installed = try await installer.install(name: name, version: version)
        installationOperation?.phase = "checking"
        var plugin = Plugin(
          id: existing.map { current[$0].id } ?? UUID().uuidString.lowercased(),
          package: name, version: version, target: installed.target, enabled: false, providers: [],
          installed: true, license: installed.license)
        plugin.providers = try await probe(plugin)
        try ensureUnique(plugin, among: current.filter { $0.isInstalled && $0.id != plugin.id })
        plugin.enabled = true
        if let existing { current[existing] = plugin } else { current.append(plugin) }
        try await save(current)
        var connected: Bool?
        if Self.supportsAutomaticPublicAccess(plugin) {
          do {
            try await connectAutomaticPublicAccess(plugin, using: sharedHost())
            connected = true
            runtimeErrors.removeValue(forKey: plugin.id)
          } catch {
            connected = false
            runtimeErrors[plugin.id] =
              "已安装，公开访问连接失败："
              + OutboundContentSecurity.redactedSecrets(
                error.localizedDescription, maximumUTF8Bytes: 1024)
          }
        }
        installationOperation?.state = "completed"
        var result: [String: ACPJSONValue] = [
          "id": .string(plugin.id), "enabled": .bool(plugin.enabled),
        ]
        if let connected { result["connected"] = .bool(connected) }
        return .object(result)
      } catch {
        installationOperation?.state = "failed"
        installationOperation?.message = OutboundContentSecurity.redactedSecrets(
          error.localizedDescription, maximumUTF8Bytes: 2048)
        throw error
      }
    }
    var current = try await records()
    guard let id = payload["id"]?.stringValue,
      let index = current.firstIndex(where: { $0.id == id && $0.isInstalled })
    else { throw ServiceCommunityProviderError.pluginMissing }
    try await stopHost()
    switch action {
    case "enable":
      guard let enabled = payload["enabled"]?.boolValue else {
        throw ServiceCommunityProviderError.invalidRequest
      }
      current[index].enabled = enabled
      try await save(current)
    case "update":
      guard let version = payload["version"]?.stringValue else {
        throw ServiceCommunityProviderError.invalidRequest
      }
      let (_, installer) = try await runtime()
      let installed = try await installer.install(name: current[index].package, version: version)
      var candidate = current[index]
      candidate.version = version
      candidate.target = installed.target
      candidate.license = installed.license
      candidate.providers = []
      candidate.providers = try await probe(candidate)
      try ensureUnique(candidate, among: current.filter { $0.id != id && $0.isInstalled })
      current[index] = candidate
      try await save(current)
      runtimeErrors.removeValue(forKey: id)
    case "remove":
      let removed = current[index]
      current[index].enabled = false
      current[index].installed = false
      try await save(current)
      let (_, installer) = try await runtime()
      do { try await installer.remove(name: removed.package) } catch {
        throw ServiceCommunityProviderError.incompatible(
          "插件已停用，但安装文件清理失败：\(error.localizedDescription)")
      }
      runtimeErrors.removeValue(forKey: id)
    default:
      throw ServiceCommunityProviderError.invalidRequest
    }
    return .object(["ok": .bool(true)])
  }

  func ensureUnique(_ plugin: Plugin, among existing: [Plugin]) throws {
    let used = Set(existing.flatMap(\.providers))
    if let conflict = plugin.providers.first(where: used.contains) {
      throw ServiceCommunityProviderError.conflictingProvider(conflict)
    }
  }

  func authentication(action: String, payload: ACPJSONValue) async throws -> ACPJSONValue {
    try beginRequest()
    defer { endRequest() }
    guard let id = payload["id"]?.stringValue, let provider = payload["provider"]?.stringValue,
      let plugin = try await records().first(where: { $0.id == id && $0.isInstalled }),
      plugin.providers.contains(provider)
    else { throw ServiceCommunityProviderError.pluginMissing }
    let client = try await sharedHost()
    if action == "authMethods" {
      let unavailable = try await unavailableAuthMethods(for: plugin)
      let row: ACPJSONValue
      let accountCount: Int?
      if payload["summary"]?.boolValue == true {
        row = try await request(
          client, method: "authMethods", params: .object(["provider": .string(provider)]))
        let summary = try? await request(
          client, method: "providerSummary", params: .object(["provider": .string(provider)]))
        accountCount = summary?["accounts"]?.arrayValue?.count
      } else {
        row = try await authenticationMethods(client, provider: provider)
        accountCount = row["accounts"]?.arrayValue?.count
      }
      guard var fields = row.objectValue else { return row }
      if let accountCount { fields["accountCount"] = .integer(Int64(accountCount)) }
      if !unavailable.isEmpty, let methods = fields["methods"]?.arrayValue {
        fields["methods"] = .array(
          methods.map { method in
            guard var values = method.objectValue, let label = values["label"]?.stringValue,
              unavailable.contains(label)
            else { return method }
            values["unavailableReason"] = .string("当前版本不支持此登录方式，详见插件说明。")
            return .object(values)
          })
      }
      return .object(fields)
    }
    var params: [String: ACPJSONValue] = ["provider": .string(provider)]
    if action == "callback" {
      guard let session = payload["session"]?.stringValue,
        let authorization = authorizations[session], authorization.pluginID == id,
        authorization.provider == provider, authorization.expires > Date()
      else { throw ServiceCommunityProviderError.invalidRequest }
      params["session"] = .string(session)
      if let code = payload["code"] { params["code"] = code }
      defer { authorizations.removeValue(forKey: session) }
      let result = try await request(
        client, method: "callback", params: .object(params), timeout: .seconds(900))
      return result
    }
    guard let method = payload["method"]?.intValue, method >= 0 else {
      throw ServiceCommunityProviderError.invalidRequest
    }
    let unavailable = try await unavailableAuthMethods(for: plugin)
    if !unavailable.isEmpty {
      let row = try await request(
        client, method: "authMethods", params: .object(["provider": .string(provider)]))
      guard let methods = row["methods"]?.arrayValue, methods.indices.contains(method) else {
        throw ServiceCommunityProviderError.invalidRequest
      }
      if let label = methods[method]["label"]?.stringValue, unavailable.contains(label) {
        throw ServiceCommunityProviderError.unavailableAuthentication
      }
    }
    params["method"] = .integer(Int64(method))
    for name in ["inputs", "key", "value"] {
      if let value = payload[name] { params[name] = value }
    }
    let methodName =
      action == "apiKey"
      ? "apiKey" : action == "prompt" ? "prompt" : action == "validate" ? "validate" : "authorize"
    let result = try await request(
      client, method: methodName, params: .object(params), timeout: .seconds(900))
    if action == "authorize", let session = result["session"]?.stringValue,
      result["ok"]?.boolValue == true
    {
      guard authorizations.count < 32 else { throw ServiceCommunityProviderError.busy }
      authorizations[session] = Authorization(
        pluginID: id, provider: provider, expires: Date().addingTimeInterval(900))
    }
    return result
  }

  func signOut(payload: ACPJSONValue) async throws -> ACPJSONValue {
    try beginRequest()
    defer { endRequest() }
    guard let id = payload["id"]?.stringValue, let provider = payload["provider"]?.stringValue,
      let plugin = try await records().first(where: { $0.id == id && $0.isInstalled }),
      plugin.providers.contains(provider)
    else { throw ServiceCommunityProviderError.pluginMissing }
    let client = try await sharedHost()
    var params: [String: ACPJSONValue] = ["provider": .string(provider)]
    if let account = payload["account"]?.stringValue, !account.isEmpty {
      params["account"] = .string(account)
    }
    _ = try await request(client, method: "signOut", params: .object(params))
    return .object(["ok": .bool(true)])
  }

  private func authenticationMethods(_ client: ProviderHostClient, provider: String) async throws
    -> ACPJSONValue
  {
    let result = try await request(
      client, method: "providers", params: .object(["provider": .string(provider)]))
    guard let row = result.arrayValue?.first else {
      throw ServiceCommunityProviderError.pluginMissing
    }
    return row
  }

  private func unavailableAuthMethods(for plugin: Plugin) async throws -> Set<String> {
    let (_, installer) = try await runtime()
    let entry = try await installer.catalog().first {
      $0.package == plugin.package && $0.version == plugin.version
    }
    return Set(entry?.unavailableAuthMethods ?? [])
  }
}
