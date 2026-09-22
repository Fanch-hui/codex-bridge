import BridgeAgentCore
import BridgeAntigravityCLI
import BridgeCodexRPC
import BridgeCodexService
import BridgeDeepSeekHarnessACP
import BridgeDirectCommand
import BridgeDomain
import BridgeLegacyImport
import BridgeMCP
import BridgeOpenCodeACP
import BridgeSecurity
import BridgeServiceApplication
import BridgeServiceCore
import Foundation

public actor ServiceComposition {
  public let paths: ServiceDataPaths
  public let store: SimpleServiceStore
  public let projects: ServiceProjectService
  public let tasks: ServiceTaskManager
  public let settings: ServiceSettings
  public let deepSeekHarnessMCP: ServiceDeepSeekHarnessMCPConfiguration
  public let agentRegistry: ServiceAgentRegistry
  let agentDiscoveryCatalog: ServiceAgentDiscoveryCatalog
  public let execution: ExecutionManager
  public let coordinator: ServiceExecutionCoordinator
  public let catalog: ServiceCodexCatalog
  public let runtimeStatus: ServiceRuntimeStatus
  public let application: BridgeServiceApplication
  public let tunnel: ServiceTunnelController
  public let mcpClients: ServiceMCPClientRegistry
  public let legacyImportReport: LegacyImportReport?

  private let configuration: ServiceCompositionConfiguration
  private let executionAppServer: CodexAppServerLocator
  private let catalogAppServer: CodexAppServerLocator
  private var mcpServer: MCPBridgeServer?
  private var mcpEndpoint: MCPBridgeEndpoint?
  private var startupAgentRefreshTask: Task<Void, Never>?
  private var tunnelBootstrapped = false
  private var isShutdown = false

  public static func make(
    configuration: ServiceCompositionConfiguration,
    secretStore: any SecretStore = SecretStoreFactory.defaultStore(),
    tunnelFactory: (any ServiceTunnelManagerBuilding)? = nil
  ) async throws -> ServiceComposition {
    try await make(
      configuration: configuration,
      secretStore: secretStore,
      randomBytes: ServiceMCPSecretProvider.secureRandomBytes,
      tunnelFactory: tunnelFactory
    )
  }

  public static func make(
    configuration: ServiceCompositionConfiguration,
    secretStore: any SecretStore = SecretStoreFactory.defaultStore(),
    randomBytes: @escaping @Sendable (Int) throws -> Data,
    tunnelFactory: (any ServiceTunnelManagerBuilding)? = nil
  ) async throws -> ServiceComposition {
    let paths = try ServiceDataPaths.prepare(at: configuration.dataRootURL)
    let store = try SimpleServiceStore(path: paths.databaseURL.path)
    let legacyImport = await Self.importLegacyConfiguration(
      from: configuration.legacyDataRootURL,
      into: store
    )
    _ = try await store.markIncompleteTasksUnknown(at: Date())
    let projects = ServiceProjectService(store: store)
    let tasks = ServiceTaskManager(store: store)
    let settings = ServiceSettings(store: store)
    let deepSeekHarnessMCP = ServiceDeepSeekHarnessMCPConfiguration(
      settings: settings, secretStore: secretStore)
    let deepSeekBaseURL = try await settings.string(for: .deepSeekHarnessBaseURL)
    let deepSeekConfigurationPath = try await settings.string(
      for: .deepSeekHarnessManagedConfigurationPath
    )
    let agentCredentials = ServiceAgentCredentialEnvironment(
      secretStore: secretStore,
      deepSeekBaseURL: deepSeekBaseURL,
      managedDeepSeekConfigurationPath: deepSeekConfigurationPath
    )
    let agentProviders: [any AgentProvider] = [
      try AntigravityCLIProvider(),
      try OpenCodeACPProvider(
        configuration: OpenCodeACPProviderConfiguration(
          persistentStateBaseDirectory: paths.agentStateURL.path
        )
      ),
      try DeepSeekHarnessACPProvider(
        configuration: DeepSeekHarnessACPProviderConfiguration(
          runtimeBaseDirectory: paths.agentStateURL
            .appendingPathComponent("DeepSeekHarnessACP", isDirectory: true).path,
          persistentStateBaseDirectory: paths.agentStateURL
            .appendingPathComponent("DeepSeekHarnessSessions", isDirectory: true).path,
          environmentProvider: { [agentCredentials] installation in
            try await agentCredentials.runtimeEnvironment(for: installation)
          },
          mcpServersProvider: { [deepSeekHarnessMCP] in
            try await deepSeekHarnessMCP.enabledRuntimeConfigurations()
          }
        )
      ),
    ]
    let agentRegistry = ServiceAgentRegistry(
      store: store,
      providers: agentProviders,
      resolveUpdatedInstallation: { existing in
        try ServiceAgentAutoDiscovery.updatedInstallationRequest(
          for: existing,
          dataPaths: paths,
          environment: ToolDiscoveryEnvironment.current()
        )
      }
    )
    let agentDiscoveryCatalog = ServiceAgentDiscoveryCatalog(
      cacheURL: paths.agentStateURL.appendingPathComponent("discovered-agents.json")
    )
    let agentRunner = ServiceAgentTaskRunner(
      registry: agentRegistry,
      providers: Dictionary(
        uniqueKeysWithValues: agentProviders.map { ($0.descriptor.providerID, $0) }
      )
    )
    let codexExecutablePath = try await settings.codexExecutablePath()
    let executionAppServer = Self.makeAppServerLocator(configuration.executionAppServer)
    executionAppServer.update(configuredPath: codexExecutablePath)
    let catalogAppServer = Self.makeAppServerLocator(configuration.catalogAppServer)
    catalogAppServer.update(configuredPath: codexExecutablePath)
    let execution = ExecutionManager(
      configuration: ExecutionManagerConfiguration(
        appServer: executionAppServer,
        clientInfo: configuration.clientInfo,
        synchronizeCodexProjects: configuration.synchronizeCodexProjects
      )
    )
    let coordinator = ServiceExecutionCoordinator(
      tasks: tasks,
      projects: projects,
      execution: execution,
      agentRunner: agentRunner,
      providerDisplayNameResolver: {
        ServiceAgentProviderPolicyRegistry.displayName(for: $0)
      }
    )
    let catalog = ServiceCodexCatalog(
      configuration: ServiceCodexCatalogConfiguration(
        appServer: catalogAppServer,
        clientInfo: configuration.clientInfo
      )
    )
    let runtimeStatus = ServiceRuntimeStatus(
      initial: ServiceRuntimeStatusSnapshot(
        mcpState: "stopped",
        tunnelState: "stopped",
        codexExecutablePath: codexExecutablePath,
        codexResolvedExecutablePath: Self.resolvedCodexExecutablePath(
          configuredPath: codexExecutablePath
        ),
        degradations: legacyImport.degradations
      )
    )
    let application = BridgeServiceApplication(
      appVersion: configuration.appVersion,
      projects: projects,
      tasks: tasks,
      settings: settings,
      coordinator: coordinator,
      catalog: catalog,
      runtimeStatus: runtimeStatus,
      agentRegistry: agentRegistry,
      agentCredentials: agentCredentials,
      directCommands: DirectCommandSessionManager(
        orphanPIDFileURL: paths.supervisorScratchURL.appending(path: "direct-command-pids.txt"),
        historyFileURL: paths.rootURL.appending(path: "direct-command-history.json")
      )
    )
    await application.startTaskQueueProcessor()
    let resolvedTunnelFactory =
      tunnelFactory
      ?? BundledServiceTunnelManagerFactory(
        appBundleURL: configuration.appBundleURL ?? URL(fileURLWithPath: "/"),
        runtimeDirectory: paths.tunnelRuntimeURL,
        secretStore: secretStore
      )
    let tunnel = ServiceTunnelController(
      settings: settings,
      runtimeStatus: runtimeStatus,
      secretStore: secretStore,
      factory: resolvedTunnelFactory
    )
    let secretProvider = ServiceMCPSecretProvider(
      store: secretStore,
      randomBytes: randomBytes
    )
    let mcpClients = try ServiceMCPClientRegistry.makeDeferred(
      settings: settings,
      secrets: secretProvider
    )
    return ServiceComposition(
      configuration: configuration,
      executionAppServer: executionAppServer,
      catalogAppServer: catalogAppServer,
      paths: paths,
      store: store,
      projects: projects,
      tasks: tasks,
      settings: settings,
      deepSeekHarnessMCP: deepSeekHarnessMCP,
      agentRegistry: agentRegistry,
      agentDiscoveryCatalog: agentDiscoveryCatalog,
      execution: execution,
      coordinator: coordinator,
      catalog: catalog,
      runtimeStatus: runtimeStatus,
      application: application,
      tunnel: tunnel,
      mcpClients: mcpClients,
      legacyImportReport: legacyImport.report
    )
  }

  public func startAgentInstallationRefresh() {
    guard startupAgentRefreshTask == nil else { return }
    let registry = agentRegistry
    let runtimeStatus = runtimeStatus
    startupAgentRefreshTask = Task {
      do {
        _ = try await registry.refreshInstallationStates()
      } catch is CancellationError {
        return
      } catch {
        let current = await runtimeStatus.current()
        let message =
          "Agents: initial installation refresh failed; stored states will be retried."
        guard !current.degradations.contains(message) else { return }
        await runtimeStatus.update(
          ServiceRuntimeStatusSnapshot(
            mcpState: current.mcpState,
            tunnelState: current.tunnelState,
            codexVersion: current.codexVersion,
            loginMode: current.loginMode,
            degradations: current.degradations + [message]
          )
        )
      }
    }
  }

  private init(
    configuration: ServiceCompositionConfiguration,
    executionAppServer: CodexAppServerLocator,
    catalogAppServer: CodexAppServerLocator,
    paths: ServiceDataPaths,
    store: SimpleServiceStore,
    projects: ServiceProjectService,
    tasks: ServiceTaskManager,
    settings: ServiceSettings,
    deepSeekHarnessMCP: ServiceDeepSeekHarnessMCPConfiguration,
    agentRegistry: ServiceAgentRegistry,
    agentDiscoveryCatalog: ServiceAgentDiscoveryCatalog,
    execution: ExecutionManager,
    coordinator: ServiceExecutionCoordinator,
    catalog: ServiceCodexCatalog,
    runtimeStatus: ServiceRuntimeStatus,
    application: BridgeServiceApplication,
    tunnel: ServiceTunnelController,
    mcpClients: ServiceMCPClientRegistry,
    legacyImportReport: LegacyImportReport?
  ) {
    self.configuration = configuration
    self.executionAppServer = executionAppServer
    self.catalogAppServer = catalogAppServer
    self.paths = paths
    self.store = store
    self.projects = projects
    self.tasks = tasks
    self.settings = settings
    self.deepSeekHarnessMCP = deepSeekHarnessMCP
    self.agentRegistry = agentRegistry
    self.agentDiscoveryCatalog = agentDiscoveryCatalog
    self.execution = execution
    self.coordinator = coordinator
    self.catalog = catalog
    self.runtimeStatus = runtimeStatus
    self.application = application
    self.tunnel = tunnel
    self.mcpClients = mcpClients
    self.legacyImportReport = legacyImportReport
  }

  @discardableResult
  public func startLocalMCP() async throws -> MCPBridgeEndpoint {
    guard !isShutdown else { throw CancellationError() }
    if let mcpEndpoint { return mcpEndpoint }
    await tunnel.pauseForMCPRestart()
    await stopMCP()
    var requestedPort = configuration.mcpPort
    var server: MCPBridgeServer?
    var attemptedServerStart = false
    do {
      let persistedPort = configuration.mcpPort == 0 ? try await settings.localMCPPort() : nil
      requestedPort = configuration.mcpPort == 0 ? persistedPort ?? 0 : configuration.mcpPort
      try await mcpClients.prepareForLocalMCP()
      let chatGPTSecret = try await mcpClients.chatGPTCredential()
      let activeServer = MCPBridgeServer(
        appVersion: configuration.appVersion,
        service: application,
        exposureMode: { [mcpClients] clientID in
          await mcpClients.exposureMode(for: clientID)
        },
        httpConfiguration: try MCPHTTPConfiguration(
          clientAuthenticator: mcpClients.authenticator,
          port: requestedPort
        ),
        clientAdmission: mcpClients.admission
      )
      server = activeServer
      attemptedServerStart = true
      let endpoint = try await activeServer.start()
      guard !isShutdown else {
        await activeServer.stop()
        throw CancellationError()
      }
      if configuration.mcpPort == 0, persistedPort == nil {
        try await settings.setLocalMCPPort(endpoint.port)
      }
      mcpServer = activeServer
      mcpEndpoint = endpoint
      await runtimeStatus.updateMCP(state: "ready")
      if tunnelBootstrapped {
        await tunnel.localMCPDidChange(
          endpoint.localURL,
          localMCPHeaderSecret: chatGPTSecret
        )
      } else {
        tunnelBootstrapped = true
        await tunnel.bootstrap(
          localMCPURL: endpoint.localURL,
          localMCPHeaderSecret: chatGPTSecret
        )
      }
      return endpoint
    } catch {
      if let server, mcpServer !== server {
        await server.stop()
      }
      let portUnavailable = attemptedServerStart && requestedPort != 0
      let state = portUnavailable ? "local_port_unavailable" : "failed"
      await runtimeStatus.updateMCP(
        state: state,
        degradation: Self.mcpDegradation(
          error: error,
          portUnavailable: portUnavailable,
          requestedPort: requestedPort
        )
      )
      if portUnavailable {
        throw ServiceLocalMCPError.localPortUnavailable(requestedPort)
      }
      throw error
    }
  }

  @discardableResult
  public func setExposureMode(_ mode: MCPServiceExposureMode) async throws
    -> MCPBridgeEndpoint
  {
    try await settings.setExposureMode(Self.serviceExposureMode(mode))
    await mcpServer?.terminateSessions(for: .chatGPT)
    return try await startLocalMCP()
  }

  public func refreshMCPInstructions() async {
    await mcpServer?.terminateSessions(for: .chatGPT)
    await mcpServer?.terminateSessions(for: .qwenStudio)
  }

  public func mcpClientStatuses() async throws -> [ServiceMCPClientStatus] {
    let profiles = try await mcpClients.profiles()
    var statuses: [ServiceMCPClientStatus] = []
    statuses.reserveCapacity(profiles.count)
    for profile in profiles {
      statuses.append(
        ServiceMCPClientStatus(
          profile: profile,
          activeSessionCount: await mcpServer?.activeSessionCount(for: profile.clientID) ?? 0,
          lastConnectedAt: mcpClients.authenticator.lastAuthenticationDate(
            for: profile.clientID
          )
        )
      )
    }
    return statuses
  }

  public func setQwenStudioEnabled(_ enabled: Bool) async throws {
    do {
      try await mcpClients.setQwenStudioEnabled(enabled)
    } catch {
      await mcpServer?.terminateSessions(for: .qwenStudio)
      throw error
    }
    await mcpServer?.terminateSessions(for: .qwenStudio)
  }

  public func setQwenStudioExposureMode(_ mode: MCPServiceExposureMode) async throws {
    try await mcpClients.setQwenStudioExposureMode(mode)
    await mcpServer?.terminateSessions(for: .qwenStudio)
  }

  public func rotateQwenStudioCredential() async throws {
    do {
      try await mcpClients.rotateQwenStudioCredential()
    } catch {
      await mcpServer?.terminateSessions(for: .qwenStudio)
      throw error
    }
    await mcpServer?.terminateSessions(for: .qwenStudio)
  }

  public func exportQwenStudioConfiguration() async throws -> String {
    let endpoint = try await startLocalMCP()
    let credential = try await mcpClients.qwenStudioCredential()
    let configuration: [String: Any] = [
      "mcpServers": [
        "Codex Bridge": [
          "type": "streamable-http",
          "url": endpoint.localURL.absoluteString,
          "headers": [MCPHTTPConfiguration.tunnelAuthenticationHeader: credential],
        ]
      ]
    ]
    let data = try JSONSerialization.data(
      withJSONObject: configuration,
      options: [.prettyPrinted, .sortedKeys]
    )
    guard let value = String(data: data, encoding: .utf8) else {
      throw ServiceMCPClientRegistryError.unsupportedClient
    }
    return value
  }

  public func rotateLocalMCPEndpoint() async throws -> MCPBridgeEndpoint {
    guard configuration.mcpPort == 0 else {
      throw ServiceLocalMCPError.endpointManagedByConfiguration
    }
    let previousPort: Int?
    if let activePort = mcpEndpoint?.port {
      previousPort = activePort
    } else {
      previousPort = try await settings.localMCPPort()
    }
    await tunnel.pauseForMCPRestart()
    await stopMCP()
    try await settings.setLocalMCPPort(nil)
    do {
      for _ in 0..<4 {
        let endpoint = try await startLocalMCP()
        guard endpoint.port == previousPort else { return endpoint }
        await tunnel.pauseForMCPRestart()
        await stopMCP()
        try await settings.setLocalMCPPort(nil)
      }
      throw ServiceLocalMCPError.localPortUnavailable(previousPort ?? 0)
    } catch {
      if let previousPort {
        try? await settings.setLocalMCPPort(previousPort)
        _ = try? await startLocalMCP()
      }
      throw error
    }
  }

  public func configureTunnel(
    tunnelID: String,
    runtimeKey: String
  ) async throws -> ServiceTunnelSnapshot {
    try await tunnel.configure(tunnelID: tunnelID, runtimeKey: runtimeKey)
  }

  public func connectTunnel() async throws -> ServiceTunnelSnapshot {
    try await tunnel.connect()
  }

  public func disconnectTunnel() async throws {
    try await tunnel.disconnect()
  }

  public func clearTunnelConfiguration() async throws {
    try await tunnel.clearConfiguration()
  }

  public func tunnelStatus() async -> ServiceTunnelSnapshot {
    await tunnel.status()
  }

  /// Applies a user-configured Codex executable. The path is validated before it
  /// is persisted, and both app-server consumers resolve it on their next spawn.
  @discardableResult
  public func setCodexExecutablePath(_ path: String?) async throws
    -> ServiceRuntimeStatusSnapshot
  {
    let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
    let configured = (trimmed?.isEmpty ?? true) ? nil : trimmed
    if let configured, AppServerConfiguration.resolveConfiguredCodexExecutable(configured) == nil {
      throw ServiceCodexExecutableError.unavailable
    }
    try await settings.setCodexExecutablePath(configured)
    executionAppServer.update(configuredPath: configured)
    catalogAppServer.update(configuredPath: configured)
    await catalog.invalidateModelCache()
    await runtimeStatus.updateCodexExecutable(
      configuredPath: configured,
      resolvedPath: Self.resolvedCodexExecutablePath(configuredPath: configured)
    )
    return await runtimeStatus.current()
  }

  private static func makeAppServerLocator(
    _ pinned: AppServerConfiguration?
  ) -> CodexAppServerLocator {
    guard let pinned else { return CodexAppServerLocator() }
    return CodexAppServerLocator(configuration: pinned)
  }

  private static func resolvedCodexExecutablePath(configuredPath: String?) -> String? {
    if let configuredPath {
      return AppServerConfiguration.resolveConfiguredCodexExecutable(configuredPath)
    }
    return AppServerConfiguration.defaultCodexExecutableURL()?.path
  }

  public func endpoint() -> MCPBridgeEndpoint? {
    mcpEndpoint
  }

  public func shutdown() async {
    guard !isShutdown else { return }
    isShutdown = true
    let refreshTask = startupAgentRefreshTask
    startupAgentRefreshTask = nil
    refreshTask?.cancel()
    _ = await refreshTask?.result
    await tunnel.shutdown()
    await stopMCP()
    await coordinator.shutdown()
    await application.shutdownDirectOperations()
    await application.shutdownTaskQueueProcessor()
    await runtimeStatus.updateMCP(state: "stopped")
  }

  private func stopMCP() async {
    let server = mcpServer
    mcpServer = nil
    mcpEndpoint = nil
    await server?.stop()
  }

  private static func importLegacyConfiguration(
    from rootURL: URL?,
    into store: SimpleServiceStore
  ) async -> LegacyConfigurationImportBootstrap {
    guard let rootURL else { return .disabled }
    do {
      let report = try await LegacyConfigurationImporter(
        legacyRootURL: rootURL,
        store: store
      ).importIfNeeded()
      return LegacyConfigurationImportBootstrap(
        report: report,
        degradations: []
      )
    } catch {
      return .failure(error: error)
    }
  }

  private static func mcpExposureMode(
    _ mode: ServiceMCPExposureMode
  ) -> MCPServiceExposureMode {
    switch mode {
    case .readOnly: .readOnly
    case .full: .full
    }
  }

  private static func serviceExposureMode(
    _ mode: MCPServiceExposureMode
  ) -> ServiceMCPExposureMode {
    switch mode {
    case .readOnly: .readOnly
    case .full: .full
    }
  }

  private static func mcpDegradation(
    error: any Error,
    portUnavailable: Bool,
    requestedPort: Int
  ) -> String {
    if let storeError = error as? SecretStoreError {
      switch storeError {
      case .accessDenied, .keychainFailure:
        return
          "MCP credentials are unavailable because the system credential store cannot be accessed."
      default:
        break
      }
    }
    return portUnavailable
      ? "Local MCP port \(requestedPort) is unavailable."
      : "Local MCP could not start."
  }
}

private struct LegacyConfigurationImportBootstrap: Sendable {
  static let disabled = LegacyConfigurationImportBootstrap(
    report: nil,
    degradations: []
  )
  static func failure(error: any Error) -> LegacyConfigurationImportBootstrap {
    LegacyConfigurationImportBootstrap(
      report: nil,
      degradations: [
        "Migration: Legacy configuration import failed (\(error)); existing Service data was left unchanged."
      ]
    )
  }

  let report: LegacyImportReport?
  let degradations: [String]
}
