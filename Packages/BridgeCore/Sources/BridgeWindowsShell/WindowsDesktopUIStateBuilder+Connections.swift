#if os(Windows)
  import BridgeDesktopUI

  extension WindowsDesktopUIStateBuilder {
    static func connectionsPage(
      workbench: WindowsWorkbenchDisplay,
      management: WindowsManagementDisplay,
      connections: WindowsConnectionDisplay?,
      settings: WindowsSettingsDisplay?
    ) -> BridgeDesktopConnectionsState? {
      guard let connections else { return nil }
      let service = statusLabel(workbench.connectionState)
      let tunnel = connections.tunnel ?? tunnelWithoutServiceStatus
      let mcpReady = workbench.connectionState == .connected && workbench.mcpState == "ready"
      let availableAgents = management.availableAgentCount
      let registeredAgents = management.agent.installationItems.count
      let message = [connections.statusText, management.agent.statusText]
        .filter { !$0.isEmpty }
        .joined(separator: "\r\n")
      return BridgeDesktopConnectionsState(
        header: header(
          "连接",
          "管理本地 MCP、Codex、本机 Agent 和 Secure Tunnel。",
          "point.3.connected.trianglepath.dotted"
        ),
        summaryRows: [
          BridgeDesktopServiceRow(
            id: "service",
            title: "后台常驻 Service",
            value: service.label,
            symbol: serviceSymbol(service.tone),
            tone: service.tone
          ),
          BridgeDesktopServiceRow(
            id: "local-mcp",
            title: "本地 MCP 通道",
            value: mcpReady ? "ready" : workbench.mcpState,
            symbol: mcpReady ? "checkmark.circle.fill" : "circle.dashed",
            tone: mcpReady ? .success : .neutral
          ),
          connectionsTunnelRow(tunnel),
          BridgeDesktopServiceRow(
            id: "agents",
            title: "本机 Agent 引擎",
            value: "\(availableAgents) 个可用 / 共 \(registeredAgents) 个",
            symbol: "cpu.fill",
            tone: availableAgents > 0 ? .success : .neutral
          ),
        ],
        localMCPURL: connections.endpointText == "—" ? nil : connections.endpointText,
        localMCPState: workbench.mcpState,
        canCopyLocalMCPURL: connections.connectionState == .connected
          && connections.endpointText.hasPrefix("http"),
        canRotateLocalMCPEndpoint: connections.rotateEndpointEnabled,
        tunnel: tunnel,
        codex: codexState(workbench: workbench, settings: settings),
        clients: connections.clientItems,
        providers: management.agent.providerItems,
        installations: management.agent.installationItems,
        canRegisterAgent: management.agent.registerEnabled,
        isManagingAgents: management.agent.isManagingAgents,
        agentOperationRevision: management.agent.agentOperationRevision,
        statusMessage: message.isEmpty ? nil : message
      )
    }

    private static func codexState(
      workbench: WindowsWorkbenchDisplay,
      settings: WindowsSettingsDisplay?
    ) -> BridgeDesktopCodexConnectionState {
      let service = statusLabel(workbench.connectionState)
      guard let settings else {
        return BridgeDesktopCodexConnectionState(
          connectionState: service.label,
          modelCount: workbench.availableModelCount,
          modelError: workbench.modelError,
          canRefresh: false,
          isConnected: workbench.connectionState == .connected && workbench.availableModelCount > 0
            && workbench.modelError == nil
        )
      }
      return BridgeDesktopCodexConnectionState(
        connectionState: service.label,
        modelCount: settings.modelOptions.count,
        modelError: settings.modelError,
        isRefreshing: settings.isRefreshingModels,
        canRefresh: !settings.busy && !settings.isRefreshingModels,
        isConnected: workbench.connectionState == .connected && !settings.modelOptions.isEmpty
          && settings.modelError == nil
      )
    }

    private static func serviceSymbol(_ tone: BridgeDesktopStatusTone) -> String {
      tone == .success ? "checkmark.circle.fill" : "circle.dashed"
    }
  }
#endif
