import BridgeDesktopUI
import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore

extension BridgeDesktopUIStateBuilder {
  static func connections(from model: BridgeServiceAppModel) -> BridgeDesktopConnectionsState {
    let tunnel = model.serviceStatus?.tunnel ?? .unconfigured
    let localState = model.serviceStatus?.status.mcpState ?? "unknown"
    return BridgeDesktopConnectionsState(
      header: BridgeDesktopPageHeader(
        title: "连接",
        subtitle: "管理本地 MCP、Codex、本机 Agent 和 Secure Tunnel。",
        symbol: BridgeServiceNavigation.connections.symbol
      ),
      summaryRows: connectionSummary(from: model, tunnel: tunnel),
      localMCPURL: model.safeLocalMCPDescription,
      localMCPState: localState,
      canCopyLocalMCPURL: model.safeLocalMCPDescription != nil,
      canRotateLocalMCPEndpoint: model.connectionState == .connected,
      tunnel: tunnelState(tunnel, connection: model.connectionState),
      codex: codexState(from: model),
      clients: clientRows(from: model),
      deepSeekHarnessMCPServers: deepSeekHarnessMCPRows(from: model),
      canManageDeepSeekHarnessMCP: model.connectionState == .connected,
      providers: model.agentProviders.map(providerRow),
      installations: model.agentInstallations.map {
        installationRow(
          $0, canManage: model.connectionState == .connected && !model.isManagingAgents)
      },
      canRegisterAgent: model.connectionState == .connected
        && !model.isManagingAgents
        && !model.agentProviders.isEmpty,
      canScanAgents: model.connectionState == .connected,
      isManagingAgents: model.isManagingAgents,
      agentOperationRevision: model.agentOperationRevision,
      statusMessage: ServiceStatusPresentation.connectionMessage(
        status: model.serviceStatus?.status,
        currentMessage: model.errorMessage
      )
    )
  }

  private static func codexState(
    from model: BridgeServiceAppModel
  ) -> BridgeDesktopCodexConnectionState {
    BridgeDesktopCodexConnectionState(
      connectionState: model.connectionState.label,
      modelCount: model.models.count,
      modelError: model.modelCatalogError,
      isRefreshing: model.isRefreshing,
      canRefresh: !model.isRefreshing,
      isConnected: model.connectionState == .connected && !model.models.isEmpty
        && model.modelCatalogError == nil,
      executablePath: model.serviceStatus?.status.codexExecutablePath,
      resolvedExecutablePath: model.serviceStatus?.status.codexResolvedExecutablePath,
      canEditExecutable: model.connectionState == .connected
    )
  }

  private static func connectionSummary(
    from model: BridgeServiceAppModel,
    tunnel: IPCTunnelStatus
  ) -> [BridgeDesktopServiceRow] {
    let mcpState = model.serviceStatus?.status.mcpState ?? "unknown"
    let tunnelTone: BridgeDesktopStatusTone =
      tunnel.lifecycle == "ready"
      ? .success : tunnel.enabled ? .running : .neutral
    return [
      BridgeDesktopServiceRow(
        id: "service",
        title: "后台常驻 Service",
        value: model.connectionState.label,
        symbol: model.connectionState.symbol,
        tone: connectionTone(for: model.connectionState),
        destination: .connections
      ),
      BridgeDesktopServiceRow(
        id: "local-mcp",
        title: "本地 MCP 通道",
        value: mcpState,
        symbol: mcpState == "ready" ? "checkmark.circle.fill" : "circle.dashed",
        tone: mcpState == "ready" ? .success : .neutral,
        destination: .connections
      ),
      BridgeDesktopServiceRow(
        id: "secure-tunnel",
        title: "远程 Secure Tunnel",
        value: tunnel.lifecycle.isEmpty ? "unknown" : tunnel.lifecycle,
        symbol: tunnel.enabled ? "link" : "circle.dashed",
        tone: tunnelTone,
        destination: .connections
      ),
      BridgeDesktopServiceRow(
        id: "agents",
        title: "本机 Agent 引擎",
        value: "\(availableAgentCount(model)) 个可用 / 共 \(model.agentInstallations.count) 个",
        symbol: "cpu.fill",
        tone: availableAgentCount(model) > 0 ? .success : .neutral,
        destination: .connections
      ),
    ]
  }

  private static func availableAgentCount(_ model: BridgeServiceAppModel) -> Int {
    model.agentInstallations.filter {
      $0.isEnabled && $0.availability == "available"
    }.count
  }

  private static func tunnelState(
    _ tunnel: IPCTunnelStatus,
    connection: BridgeServiceConnectionState
  ) -> BridgeDesktopTunnelState {
    let connected = connection == .connected
    return BridgeDesktopTunnelState(
      configured: tunnel.configured,
      enabled: tunnel.enabled,
      helperAvailable: tunnel.helperAvailable,
      tunnelID: tunnel.tunnelID,
      lifecycle: tunnel.lifecycle,
      acceptsRemoteSubmissions: tunnel.acceptsRemoteSubmissions,
      actionRequired: tunnel.actionRequired,
      canConfigure: connected && tunnel.helperAvailable,
      canConnect: connected && tunnel.configured && tunnel.helperAvailable && !tunnel.enabled,
      canDisconnect: connected && tunnel.enabled,
      canClear: connected && tunnel.configured
    )
  }

  private static let exposureOptions = [
    BridgeDesktopChoice(id: MCPServiceExposureMode.readOnly.rawValue, title: "只读"),
    BridgeDesktopChoice(id: MCPServiceExposureMode.full.rawValue, title: "完整"),
  ]

  private static func clientRows(
    from model: BridgeServiceAppModel
  ) -> [BridgeDesktopMCPClientRow] {
    let chat =
      model.mcpClients.first { $0.clientID == MCPClientID.chatGPT.rawValue }
      ?? IPCMCPClientStatus(
        clientID: MCPClientID.chatGPT.rawValue,
        displayName: "ChatGPT / OpenAI Tunnel",
        enabled: true,
        exposureMode: model.exposureMode,
        activeSessionCount: 0
      )
    let qwen =
      model.mcpClients.first { $0.clientID == MCPClientID.qwenStudio.rawValue }
      ?? IPCMCPClientStatus(
        clientID: MCPClientID.qwenStudio.rawValue,
        displayName: "Qwen Studio",
        enabled: false,
        exposureMode: .readOnly,
        activeSessionCount: 0
      )
    return [clientRow(chat, canToggle: false), clientRow(qwen, canToggle: true)]
  }

  private static func clientRow(
    _ client: IPCMCPClientStatus,
    canToggle: Bool
  ) -> BridgeDesktopMCPClientRow {
    let qwen = client.clientID == MCPClientID.qwenStudio.rawValue
    return BridgeDesktopMCPClientRow(
      clientID: client.clientID,
      displayName: client.displayName,
      enabled: client.enabled,
      exposureMode: client.exposureMode.rawValue,
      exposureOptions: exposureOptions,
      activeSessionCount: client.activeSessionCount,
      lastConnectedAt: client.lastConnectedAt,
      canToggle: canToggle,
      canCopyConfiguration: qwen,
      canRotateCredential: qwen
    )
  }

  private static func deepSeekHarnessMCPRows(
    from model: BridgeServiceAppModel
  ) -> [BridgeDesktopDeepSeekHarnessMCPRow] {
    model.deepSeekHarnessMCPServers.map { server in
      BridgeDesktopDeepSeekHarnessMCPRow(
        id: server.id,
        name: server.name,
        enabled: server.enabled,
        transport: server.transport,
        command: server.command,
        arguments: server.args,
        url: server.url,
        environment: server.environment.map {
          BridgeDesktopSecretSummary(name: $0.name, hasValue: $0.hasValue)
        },
        headers: server.headers.map {
          BridgeDesktopSecretSummary(name: $0.name, hasValue: $0.hasValue)
        },
        canToggle: true,
        canEdit: true,
        canDelete: true
      )
    }
  }

  private static func providerRow(
    _ provider: IPCAgentProviderSummary
  ) -> BridgeDesktopAgentProviderRow {
    let detail = [
      provider.workspaceEnforcement,
      provider.approvalEnforcement,
      provider.networkEnforcement,
    ].filter { !$0.isEmpty }.joined(separator: " · ")
    return BridgeDesktopAgentProviderRow(
      providerID: provider.providerID,
      displayName: provider.displayName,
      adapterRevision: provider.adapterRevision,
      discoveryState: provider.discoveryState,
      discoveryMessage: provider.discoveryMessage,
      discoveredExecutablePath: provider.discoveredExecutablePath,
      discoveredConfigurationPath: provider.discoveredConfigurationPath,
      configuredBaseURL: provider.configuredBaseURL,
      requiresConfiguration: provider.requiresConfiguration,
      requiresHeadlessAlwaysProceed: provider.requiresHeadlessAlwaysProceed,
      supportsModelSelection: provider.supportsModelSelection,
      supportsEffortSelection: provider.supportsEffortSelection,
      supportsSteer: provider.supportsSteer,
      supportsWorkspaceWrite: provider.supportsWorkspaceWrite,
      detail: detail.isEmpty ? nil : detail
    )
  }

  private static func installationRow(
    _ installation: IPCAgentInstallationSummary,
    canManage: Bool
  ) -> BridgeDesktopAgentInstallationRow {
    BridgeDesktopAgentInstallationRow(
      installationID: installation.installationID,
      providerID: installation.providerID,
      displayName: installation.displayName,
      executablePath: installation.executablePath,
      version: installation.version,
      protocolRevision: installation.protocolRevision,
      adapterRevision: installation.adapterRevision,
      trustProfile: installation.trustProfile,
      securityProfileID: installation.securityProfileID,
      enabled: installation.isEnabled,
      availability: installation.availability,
      effectiveCapabilities: installation.effectiveCapabilities,
      lastProbeError: installation.lastProbeError,
      lastProbedAt: installation.lastProbedAt,
      updatedAt: installation.updatedAt,
      canToggle: canManage && (installation.isEnabled || installation.availability == "available"),
      canReprobe: canManage,
      canRemove: canManage
    )
  }
}
