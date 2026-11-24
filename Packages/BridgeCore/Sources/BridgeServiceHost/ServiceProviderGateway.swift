import BridgeACP
import BridgeEmbeddedDSH
import BridgeIPC
import BridgeModelGateway
import BridgeProviderRuntime
import BridgeSecurity
import BridgeServiceCore
import Foundation

actor ServiceProviderGateway {
  let store: SimpleServiceStore
  let existing: ServiceExistingProviders
  let dataRoot: URL
  let resourceRoot: URL?
  let authentication = ServiceGatewayAuthentication()
  let scheduler = ModelGatewayRequestScheduler()
  let conversionHost = ServiceModelConversionHost()
  var listener: ModelGatewayListener?
  var endpoint: ModelGatewayEndpoint?
  var enabled = false
  var changingService = false
  var models: [ServiceGatewayModel] = []
  private let modelWrite = AsyncMutex()
  var deadlines = GatewayDeadlineSettings.defaults
  var savingDeadlines = false
  var activeRequests: [String: ACPJSONValue] = [:]
  var activityError: String?
  var activitySummaryCache: ACPJSONValue?
  var communityModelTask: Task<ACPJSONValue, any Error>?
  var communityModelsInvalidated = false
  var communityModelError: String?
  var serviceError: String?
  var resourcesCache: ProviderRuntimeResources?
  var resourcesLoading: Task<ProviderRuntimeResources, any Error>?
  var applicationMode: ServiceApplicationModeController?
  var externalApplications: ServiceExternalApplications?
  var communityProviders: ServiceCommunityProviders?
  var workbenchGateway: ServiceWorkbenchGateway?
  var anthropicPassthroughBaseURL = URL(string: "https://api.anthropic.com")!
  var codexUpstreamEndpoints = CodexUpstreamEndpoints.official
  var codexOfficialModels = CodexOfficialModelCache()

  func attach(
    mode: ServiceApplicationModeController, applications: ServiceExternalApplications,
    community: ServiceCommunityProviders
  ) {
    applicationMode = mode
    externalApplications = applications
    communityProviders = community
  }

  func endpointURL() throws -> URL {
    guard let endpoint, let url = URL(string: "http://127.0.0.1:\(endpoint.port)/v1") else {
      throw ServiceStoreError.invalidArgument("gateway.not_running")
    }
    return url
  }

  func isGatewayRunning() -> Bool { endpoint != nil }

  func modelDisplayNames() -> [String: String] {
    Dictionary(models.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
  }

  func modelLimits() -> [String: ExternalAgentModelLimit] {
    Dictionary(
      models.compactMap { model in
        model.knownContextWindow == nil && model.defaultMaxTokens == nil
          && model.reasoningEfforts == nil
          ? nil
          : (
            model.id,
            ExternalAgentModelLimit(
              contextWindow: model.knownContextWindow, maxOutputTokens: model.defaultMaxTokens,
              reasoningEfforts: model.reasoningEfforts)
          )
      }, uniquingKeysWith: { first, _ in first })
  }

  init(
    store: SimpleServiceStore, existing: ServiceExistingProviders, dataRoot: URL,
    resourceRoot: URL? = nil
  ) {
    self.store = store
    self.existing = existing
    self.dataRoot = dataRoot
    self.resourceRoot = resourceRoot
  }

  func resources() async throws -> ProviderRuntimeResources {
    if let resourcesCache { return resourcesCache }
    if let resourcesLoading { return try await resourcesLoading.value }
    let root = try EmbeddedDSHRuntimeConfiguration(
      resourceRoot: resourceRoot, dataRoot: dataRoot
    ).resolveResourceRoot()
    let loading = Task { try await ProviderRuntimeResources.shared(root: root) }
    resourcesLoading = loading
    do {
      let value = try await loading.value
      resourcesCache = value
      resourcesLoading = nil
      return value
    } catch {
      resourcesLoading = nil
      throw error
    }
  }

  func restore() async throws {
    if let value = try await store.setting(key: "gateway.deadlines")?.value {
      deadlines = try GatewayDeadlineSettings(
        payload: JSONDecoder().decode(ACPJSONValue.self, from: Data(value.utf8)))
    }
    if let value = try await store.setting(key: "gateway.models")?.value {
      models = try JSONDecoder().decode([ServiceGatewayModel].self, from: Data(value.utf8))
    }
    do {
      if let communityProviders,
        try await communityProviders.records().contains(where: { $0.isInstalled && $0.enabled })
          || models.contains(where: { $0.pluginID != nil })
      {
        invalidateCommunityModels()
      }
    } catch {
      communityModelError = OutboundContentSecurity.redactedSecrets(
        error.localizedDescription, maximumUTF8Bytes: 1024)
    }
    if try await store.setting(key: "gateway.enabled")?.value == "true" {
      do {
        try await setEnabled(true)
      } catch {
        enabled = true
        serviceError = "模型网关未能启动，请检查本机端口占用后重新启动服务。"
      }
    }
  }

  func setEnabled(_ value: Bool) async throws {
    guard !changingService else { throw ModelGatewayError.lifecycleTransitionInProgress }
    guard value != enabled || (value && endpoint == nil) else { return }
    changingService = true
    defer { changingService = false }
    if value {
      let savedPort = try await store.setting(key: "gateway.port")?.value
      let port = savedPort.flatMap(Int.init) ?? 0
      let server = ModelGatewayListener(
        configuration: try ModelGatewayConfiguration(port: port),
        authenticate: { [authentication] in authentication.authenticate($0) },
        handler: { [weak self] request, sink in
          guard let self else { throw CancellationError() }
          try await self.handle(request, sink: sink)
        },
        webSocketHandler: { [weak self, authentication] request in
          guard let self else { return .reject(status: 503) }
          return await self.acceptCodexWebSocket(request, authentication: authentication)
        })
      let address = try await server.start()
      do {
        try await save("gateway.port", String(address.port))
        try await save("gateway.enabled", "true")
      } catch {
        await server.shutdown(force: true)
        throw error
      }
      listener = server
      endpoint = address
      await scheduler.resumeAccepting()
      enabled = true
      serviceError = nil
    } else {
      try await save("gateway.enabled", "false")
      await listener?.shutdown()
      listener = nil
      endpoint = nil
      enabled = false
      serviceError = nil
      await conversionHost.stopWhenIdle()
    }
  }

  func serviceStatus() async -> ACPJSONValue {
    let counts = await scheduler.counts()
    return .object([
      "enabled": .bool(enabled), "running": .bool(endpoint != nil),
      "error": serviceError.map(ACPJSONValue.string) ?? .null,
      "url": endpoint.map { .string("http://127.0.0.1:\($0.port)/v1") } ?? .null,
      "active": .integer(Int64(counts.active)), "queued": .integer(Int64(counts.queued)),
    ])
  }

  func refreshModels() async throws -> ACPJSONValue {
    let catalog = try await existing.call("models.list", payload: .object(["refresh": .bool(true)]))
    var discovered: [ServiceGatewayModel] = []
    for group in catalog["groups"]?.arrayValue ?? [] {
      guard let provider = group["id"]?.stringValue else { continue }
      for model in group["models"]?.arrayValue ?? [] {
        guard let id = model["id"]?.stringValue else { continue }
        discovered.append(
          ServiceGatewayModel(
            id: "builtin/" + provider + "/" + id, name: model["name"]?.stringValue ?? id,
            providerID: provider, modelID: id, pluginID: nil, protocolName: "chat", account: nil,
            contextWindow: model["contextWindow"]?.intValue.flatMap { $0 > 0 ? $0 : nil },
            providerName: group["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
            reasoningEfforts: ServiceGatewayModel.reasoningEfforts(
              (model["reasoning"]?["efforts"]?.arrayValue ?? []).compactMap {
                $0["id"]?.stringValue
              })))
      }
    }
    // Failed providers retain their last usable model names; authentication is reported separately.
    let failed = Set((catalog["failures"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue })
    discovered += models.filter { $0.pluginID == nil && failed.contains($0.providerID) }
    _ = try await refreshCommunityModels()
    return try await publishModels(
      discovered, community: false,
      failures: catalog["failures"] ?? .array([]))
  }

  func invalidateCommunityModels() {
    communityModelsInvalidated = true
    _ = communityRefreshTask()
  }

  func refreshCommunityModels() async throws -> ACPJSONValue {
    try await communityRefreshTask().value
  }

  private func communityRefreshTask() -> Task<ACPJSONValue, any Error> {
    if let communityModelTask { return communityModelTask }
    let task = Task {
      defer { communityModelTask = nil }
      guard let communityProviders else {
        throw ServiceStoreError.invalidArgument("gateway.not_initialized")
      }
      do {
        while true {
          try Task.checkCancellation()
          communityModelsInvalidated = false
          let community = try await communityProviders.models()
          if communityModelsInvalidated { continue }
          let changed = community != models.filter { $0.pluginID != nil }
          let result = try await publishModels(community, community: true, failures: .array([]))
          if changed { await existing.workbench?.communityModelsChanged() }
          if !communityModelsInvalidated {
            communityModelError = nil
            return result
          }
        }
      } catch {
        communityModelError = OutboundContentSecurity.redactedSecrets(
          error.localizedDescription, maximumUTF8Bytes: 1024)
        throw error
      }
    }
    communityModelTask = task
    return task
  }

  private func publishModels(
    _ discovered: [ServiceGatewayModel], community: Bool, failures: ACPJSONValue
  )
    async throws -> ACPJSONValue
  {
    await modelWrite.acquire()
    defer { modelWrite.release() }
    let next =
      community
      ? models.filter { $0.pluginID == nil } + discovered
      : discovered + models.filter { $0.pluginID != nil }
    if next != models {
      try await save("gateway.models", String(decoding: JSONEncoder().encode(next), as: UTF8.self))
      models = next
    }
    return .object(["models": .array(models.map(\.presentation)), "failures": failures])
  }

  func stopAccepting() async {
    await scheduler.stopAccepting()
    await listener?.stopAccepting()
    await workbenchGateway?.stopAccepting()
    await conversionHost.stopWhenIdle()
  }

  func shutdown() async throws {
    communityModelTask?.cancel()
    _ = await communityModelTask?.result
    await scheduler.stopAccepting()
    await workbenchGateway?.shutdown()
    workbenchGateway = nil
    await listener?.shutdown()
    listener = nil
    endpoint = nil
    // Requests are drained by now. Later teardown still runs when the helper's exit is unconfirmed.
    var helperFailure: (any Error)?
    do { try await conversionHost.stop() } catch { helperFailure = error }
    if let communityProviders { try await communityProviders.shutdown() }
    try await existing.shutdown()
    if let helperFailure { throw helperFailure }
  }

  func save(_ key: String, _ value: String) async throws {
    try await store.setSetting(ServiceSettingRecord(key: key, value: value, updatedAt: Date()))
  }
}
