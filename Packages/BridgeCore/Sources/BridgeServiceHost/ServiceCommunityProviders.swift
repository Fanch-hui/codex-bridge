import BridgeACP
import BridgeProviderRuntime
import BridgeSecurity
import BridgeServiceCore
import Foundation

actor ServiceCommunityProviders {
  struct Plugin: Codable, Sendable {
    let id: String
    let package: String
    var version: String
    var target: String
    var enabled: Bool
    var providers: [String]
    var installed: Bool? = nil
    var license: String? = nil

    var isInstalled: Bool { installed != false }
  }

  struct InstallationOperation: Sendable {
    let operationID: String
    let package: String
    let version: String
    var state = "running"
    var phase = "preparing"
    var message: String?

    var presentation: ACPJSONValue {
      var fields: [String: ACPJSONValue] = [
        "operationID": .string(operationID), "action": .string("install"),
        "package": .string(package), "version": .string(version), "state": .string(state),
      ]
      if state == "running" { fields["phase"] = .string(phase) }
      if let message { fields["message"] = .string(message) }
      return .object(fields)
    }
  }

  struct Authorization: Sendable {
    let pluginID: String
    let provider: String
    let expires: Date
  }

  let store: SimpleServiceStore
  let secrets: any SecretStore
  let resourceLoader: @Sendable () async throws -> ProviderRuntimeResources
  let directory: URL
  var cachedResources: ProviderRuntimeResources?
  var installer: CommunityProviderInstallation?
  var cachedCatalog: [String: CommunityProviderCatalogEntry]?
  var resourceLoading: Task<ProviderRuntimeResources, any Error>?
  var plugins: [Plugin]?
  var loading: Task<[Plugin], any Error>?
  var host: ProviderHostClient?
  var starting: Task<ProviderHostClient, any Error>?
  var idle: Task<Void, Never>?
  var active = 0
  var changing = false
  var shuttingDown = false
  var drainWaiters: [CheckedContinuation<Void, Never>] = []
  var authorizations: [String: Authorization] = [:]
  var installationOperation: InstallationOperation?
  var routes: [String: CommunityModelRoute] = [:]
  var persistedRoutes: [String: [CommunityCachedModel]] = [:]
  var loadedModelCaches: Set<String> = []
  var staleModels: Set<String> = []
  var modelRefresh: Task<[ServiceGatewayModel], any Error>?
  var accountRequests: [String: Int] = [:]
  var runtimeErrors: [String: String] = [:]
  var updateChecks: [String: Task<String, any Error>] = [:]
  static let settingKey = "providers.community.plugins"

  init(
    store: SimpleServiceStore, secrets: any SecretStore, directory: URL,
    resources: @escaping @Sendable () async throws -> ProviderRuntimeResources
  ) {
    self.store = store
    self.secrets = secrets
    resourceLoader = resources
    self.directory = directory
  }

  func status() async throws -> ACPJSONValue {
    let records = try await records()
    let catalogByPackage = await catalogIndex()
    return .array(
      records.filter(\.isInstalled).map { record in
        var value: [String: ACPJSONValue] = [
          "id": .string(record.id), "package": .string(record.package),
          "version": .string(record.version), "enabled": .bool(record.enabled),
          "verified": .bool(false), "stale": .bool(staleModels.contains(record.id)),
          "providers": .array(
            record.providers.map {
              .object(["id": .string($0), "name": .string($0)])
            }),
        ]
        if let error = runtimeErrors[record.id] { value["error"] = .string(error) }
        if let license = record.license { value["license"] = .string(license) }
        if let entry = catalogByPackage[record.package] {
          value["name"] = .string(entry.name)
          value["source"] = .string(entry.source)
          value["catalogListed"] = .bool(true)
          if let accessMode = entry.accessMode { value["accessMode"] = .string(accessMode) }
          if let summary = entry.summary { value["summary"] = .string(summary) }
          if let requirements = entry.requirements { value["requirements"] = .string(requirements) }
          if let setup = entry.environmentSetup { value["environmentSetup"] = .string(setup) }
          if let steps = entry.usageSteps {
            value["usageSteps"] = .array(steps.map(ACPJSONValue.string))
          }
          if let limit = entry.limitSummary { value["limitSummary"] = .string(limit) }
          if let compat = entry.compatibility { value["compatibility"] = .string(compat) }
          if let details = entry.compatibilityDetails {
            value["compatibilityDetails"] = .string(details)
          }
        }
        return .object(value)
      })
  }

  private func catalogIndex() async -> [String: CommunityProviderCatalogEntry] {
    if let cachedCatalog { return cachedCatalog }
    guard let installer, let entries = try? await installer.catalog() else { return [:] }
    let index = Dictionary(
      entries.map { ($0.package, $0) }, uniquingKeysWith: { first, _ in first })
    cachedCatalog = index
    return index
  }

  func snapshot() async throws -> (plugins: ACPJSONValue, operation: ACPJSONValue) {
    let plugins = try await status()
    return (plugins, installationOperation?.presentation ?? .null)
  }

  func call(action: String, payload: ACPJSONValue) async throws -> ACPJSONValue {
    guard !shuttingDown else { throw ServiceCommunityProviderError.stopped }
    let action = action.hasPrefix("plugins.") ? String(action.dropFirst(8)) : action
    switch action {
    case "catalog":
      // The bundled catalog is immutable during plugin installation.
      let (_, installer) = try await runtime()
      let entries = try await installer.catalog()
      cachedCatalog = Dictionary(
        entries.map { ($0.package, $0) }, uniquingKeysWith: { first, _ in first })
      return try Self.json(entries)
    case "install", "update", "enable", "remove":
      return try await change(action: action, payload: payload)
    case "authMethods", "prompt", "validate", "authorize", "callback", "apiKey":
      return try await authentication(action: action, payload: payload)
    case "signOut":
      return try await signOut(payload: payload)
    case "usage":
      return try await usage(payload: payload)
    case "checkUpdate":
      return try await checkUpdate(payload: payload)
    default:
      throw ServiceCommunityProviderError.invalidRequest
    }
  }

  func runtime() async throws -> (ProviderRuntimeResources, CommunityProviderInstallation) {
    if let cachedResources, let installer { return (cachedResources, installer) }
    let task: Task<ProviderRuntimeResources, any Error>
    if let resourceLoading {
      task = resourceLoading
    } else {
      let loader = resourceLoader
      task = Task { try await loader() }
      resourceLoading = task
    }
    do {
      let value = try await task.value
      if let cachedResources, let installer { return (cachedResources, installer) }
      let installation = try CommunityProviderInstallation(resources: value, directory: directory)
      cachedResources = value
      installer = installation
      resourceLoading = nil
      return (value, installation)
    } catch {
      resourceLoading = nil
      throw error
    }
  }

  func records() async throws -> [Plugin] {
    if let plugins { return plugins }
    let task: Task<[Plugin], any Error>
    if let loading {
      task = loading
    } else {
      let store = store
      task = Task {
        guard let value = try await store.setting(key: Self.settingKey)?.value else { return [] }
        let records = try JSONDecoder().decode([Plugin].self, from: Data(value.utf8))
        let installed = records.filter(\.isInstalled)
        guard records.count <= 256, installed.count <= 64,
          Set(records.map(\.id)).count == records.count,
          Set(records.map(\.package)).count == records.count,
          Set(installed.flatMap(\.providers)).count == installed.flatMap(\.providers).count,
          records.allSatisfy({ UUID(uuidString: $0.id) != nil && !$0.providers.isEmpty })
        else { throw ServiceCommunityProviderError.invalidStoredConfiguration }
        return records
      }
      loading = task
    }
    do {
      let result = try await task.value
      if plugins == nil { plugins = result }
      loading = nil
      return plugins ?? result
    } catch {
      loading = nil
      throw error
    }
  }

  func save(_ value: [Plugin]) async throws {
    let data = try JSONEncoder().encode(value)
    let record = try ServiceSettingRecord(
      key: Self.settingKey, value: String(decoding: data, as: UTF8.self), updatedAt: Date())
    try await store.setSetting(record)
    let previous = plugins ?? []
    let unchanged = Set(
      value.filter { candidate in
        candidate.enabled
          && previous.contains {
            $0.id == candidate.id && $0.enabled && $0.version == candidate.version
              && $0.target == candidate.target && $0.providers == candidate.providers
          }
      }.map(\.id))
    plugins = value
    routes = routes.filter { $0.value.model.pluginID.map(unchanged.contains) ?? false }
    persistedRoutes = persistedRoutes.filter { unchanged.contains($0.key) }
    loadedModelCaches.formIntersection(unchanged)
    staleModels.formIntersection(unchanged)
  }

  func beginRequest() throws {
    guard !shuttingDown else { throw ServiceCommunityProviderError.stopped }
    guard !changing else { throw ServiceCommunityProviderError.busy }
    active += 1
    idle?.cancel()
    idle = nil
  }

  func endRequest() {
    active -= 1
    notifyDrained()
    scheduleIdle()
  }

  func notifyDrained() {
    guard active == 0, !changing else { return }
    let waiters = drainWaiters
    drainWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  func shutdown() async throws {
    shuttingDown = true
    idle?.cancel()
    idle = nil
    if active > 0 || changing {
      await withCheckedContinuation { drainWaiters.append($0) }
    }
    authorizations.removeAll()
    try await stopHost()
  }

  static func json<T: Encodable>(_ value: T) throws -> ACPJSONValue {
    try JSONDecoder().decode(ACPJSONValue.self, from: JSONEncoder().encode(value))
  }
}

enum ServiceCommunityProviderError: Error, LocalizedError, Sendable {
  case busy
  case invalidRequest
  case invalidStoredConfiguration
  case pluginMissing
  case duplicatePlugin
  case conflictingProvider(String)
  case incompatible(String)
  case unavailableAuthentication
  case stopped
  case unsupportedProtocol(String)
  case modelUnavailable

  var errorDescription: String? {
    switch self {
    case .busy: "社区供应商正在处理请求或登录，请完成后重试。"
    case .invalidRequest: "社区供应商请求无效。"
    case .invalidStoredConfiguration: "社区供应商配置无效。"
    case .pluginMissing: "社区供应商不存在。"
    case .duplicatePlugin: "该供应商插件已安装。"
    case .conflictingProvider(let provider): "供应商标识 \(provider) 与已安装插件冲突。"
    case .incompatible(let message): "插件无法加载：\(message)"
    case .unavailableAuthentication: "当前版本不支持此登录方式，详见插件说明。"
    case .stopped: "社区供应商宿主尚未完全退出。"
    case .unsupportedProtocol(let name): "暂不支持供应商模型协议：\(name)"
    case .modelUnavailable: "所选社区供应商模型或账号不可用。"
    }
  }
}
