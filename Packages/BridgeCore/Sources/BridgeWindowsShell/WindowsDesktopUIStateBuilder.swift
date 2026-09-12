#if os(Windows)
  import BridgeDesktopUI
  import Foundation

  /// Projects the live Windows shell snapshots into the shared desktop UI
  /// contract consumed by the macOS and Windows hosts.
  enum WindowsDesktopUIStateBuilder {
    static func build(
      workbench: WindowsWorkbenchDisplay,
      management: WindowsManagementDisplay,
      workspace: WindowsWorkspaceDisplay? = nil,
      logs: WindowsLogDisplay? = nil,
      connections: WindowsConnectionDisplay? = nil,
      settings: WindowsSettingsDisplay? = nil,
      agentDefaults: WindowsAgentDefaultsDisplay? = nil,
      selectedNavigation: BridgeDesktopNavigation = .overview,
      isRefreshing: Bool = false,
      browserAvailable: Bool = true,
      browserURL: String? = nil,
      browserStatus: String? = nil,
      browserCanGoBack: Bool = false,
      browserCanGoForward: Bool = false,
      feedback: BridgeDesktopFeedback? = nil
    ) -> BridgeDesktopUIState {
      let modelRefreshInProgress = settings?.isRefreshingModels == true
      let canRefreshModels = settings?.busy != true
      return BridgeDesktopUIState(
        hostContext: BridgeDesktopHostContext(platform: .windows),
        navigation: navigation(
          workbench: workbench,
          management: management
        ),
        selectedNavigation: selectedNavigation,
        connectionLabel: connectionLabel(for: workbench.connectionState),
        connectionTone: connectionTone(for: workbench.connectionState),
        isRefreshing: isRefreshing || modelRefreshInProgress,
        feedback: feedback,
        overview: overview(
          workbench: workbench,
          management: management,
          tunnel: connections?.tunnel
        ),
        workbench: workbenchPage(
          workbench,
          management: management,
          browserAvailable: browserAvailable,
          browserURL: browserURL,
          browserStatus: browserStatus,
          browserCanGoBack: browserCanGoBack,
          browserCanGoForward: browserCanGoForward,
          modelRefreshInProgress: modelRefreshInProgress,
          canRefreshModels: canRefreshModels
        ),
        projects: projectsPage(
          workbench: workbench,
          management: management,
          workspace: workspace
        ),
        logs: logsPage(logs),
        connections: connectionsPage(
          workbench: workbench,
          management: management,
          connections: connections
        ),
        settings: settingsPage(
          settings: settings,
          agentDefaults: agentDefaults
        )
      )
    }

    private static func overview(
      workbench: WindowsWorkbenchDisplay,
      management: WindowsManagementDisplay,
      tunnel: BridgeDesktopTunnelState?
    ) -> BridgeDesktopOverviewState {
      let projectCount = management.project.rows.count
      let installationCount = management.agent.installationRows.count
      let metrics = [
        metric(
          id: "running-tasks",
          title: "运行中任务",
          value: workbench.runningTaskCount,
          symbol: "bolt.fill",
          subtitle: workbench.runningTaskCount > 0 ? "点击进入工作台" : "当前空闲",
          tone: workbench.runningTaskCount > 0 ? .running : .neutral,
          destination: .workbench
        ),
        metric(
          id: "pending-approvals",
          title: "待审批项",
          value: workbench.pendingApprovalCount,
          symbol: "shield.lefthalf.filled",
          subtitle: workbench.pendingApprovalCount > 0 ? "点击立即处理审批" : "无阻断事项",
          tone: workbench.pendingApprovalCount > 0 ? .warning : .neutral,
          destination: .workbench
        ),
        metric(
          id: "registered-projects",
          title: "注册项目",
          value: projectCount,
          symbol: "folder.fill",
          subtitle: "管理本地目录",
          tone: projectCount > 0 ? .running : .neutral,
          destination: .projects
        ),
        metric(
          id: "local-agents",
          title: "本机 Agent",
          value: management.availableAgentCount,
          symbol: "cpu.fill",
          subtitle: "共 \(installationCount) 个已登记",
          tone: management.availableAgentCount > 0 ? .success : .neutral,
          destination: .connections
        ),
        metric(
          id: "total-tasks",
          title: "任务总数",
          value: workbench.taskCount,
          symbol: "list.bullet.rectangle",
          subtitle: "任务历史",
          tone: workbench.taskCount > 0 ? .running : .neutral,
          destination: .workbench
        ),
      ]

      return BridgeDesktopOverviewState(
        title: "概览",
        subtitle: "全景监控后台 Service、本地 MCP、Secure Tunnel 与任务执行状态。",
        notices: notices(workbench: workbench),
        metrics: metrics,
        services: services(
          workbench: workbench,
          management: management,
          tunnel: tunnel
        ),
        serviceActions: [
          BridgeDesktopActionLink(
            id: "manage-connections",
            title: "管理连接与 Agent →",
            command: .openConnections,
            destination: .connections
          ),
          BridgeDesktopActionLink(
            id: "configure-preferences",
            title: "配置模型与执行偏好 →",
            command: .openSettings,
            destination: .settings
          ),
        ],
        recentTasks: workbench.recentTasks.prefix(4).map {
          BridgeDesktopRecentTask(
            id: $0.taskID,
            title: $0.title,
            projectName: $0.projectName,
            source: $0.source,
            status: $0.status,
            updatedAt: $0.updatedAt
          )
        },
        lastUpdatedAt: workbench.recentTasks.map(\.updatedAt).max()
      )
    }

    private static func metric(
      id: String,
      title: String,
      value: Int,
      symbol: String,
      subtitle: String,
      tone: BridgeDesktopStatusTone,
      destination: BridgeDesktopNavigation
    ) -> BridgeDesktopMetric {
      BridgeDesktopMetric(
        id: id,
        title: title,
        value: String(value),
        symbol: symbol,
        subtitle: subtitle,
        tone: tone,
        destination: destination
      )
    }

    private static func services(
      workbench: WindowsWorkbenchDisplay,
      management: WindowsManagementDisplay,
      tunnel: BridgeDesktopTunnelState?
    ) -> [BridgeDesktopServiceRow] {
      let serviceState = connectionStatePresentation(workbench.connectionState)
      let mcpState = mcpPresentation(for: workbench)
      let available = management.availableAgentCount
      let registered = management.agent.installationRows.count
      return [
        BridgeDesktopServiceRow(
          id: "service",
          title: "后台常驻 Service",
          value: serviceState.label,
          symbol: serviceState.symbol,
          tone: serviceState.tone,
          destination: .connections
        ),
        BridgeDesktopServiceRow(
          id: "local-mcp",
          title: "本地 MCP 通道",
          value: mcpState.label,
          symbol: mcpState.symbol,
          tone: mcpState.tone,
          destination: .connections
        ),
        overviewTunnelRow(tunnel),
        BridgeDesktopServiceRow(
          id: "local-agents",
          title: "本机 Agent 引擎",
          value: "\(available) 个可用 / 共 \(registered) 个",
          symbol: "cpu.fill",
          tone: available > 0 ? .success : .neutral,
          destination: .connections
        ),
      ]
    }

    private static func mcpPresentation(
      for workbench: WindowsWorkbenchDisplay
    ) -> (label: String, symbol: String, tone: BridgeDesktopStatusTone) {
      guard workbench.connectionState == .connected else {
        let state = connectionStatePresentation(workbench.connectionState)
        return (state.label, state.symbol, state.tone)
      }
      let state = workbench.mcpState.trimmingCharacters(in: .whitespacesAndNewlines)
      guard state == "ready" else {
        return (state.isEmpty ? "未知" : state, "circle.dashed", .neutral)
      }
      return ("ready", "checkmark.circle.fill", .success)
    }

    private static func connectionStatePresentation(
      _ state: WindowsWorkbenchDisplay.ConnectionState
    ) -> (label: String, symbol: String, tone: BridgeDesktopStatusTone) {
      switch state {
      case .idle:
        ("未连接", "circle.dashed", .neutral)
      case .connecting:
        ("连接中…", "circle.dashed", .running)
      case .connected:
        ("已连接", "checkmark.circle.fill", .success)
      case .unavailable:
        ("不可用", "circle.dashed", .error)
      }
    }

    private static func connectionLabel(
      for state: WindowsWorkbenchDisplay.ConnectionState
    ) -> String {
      connectionStatePresentation(state).label
    }

    private static func connectionTone(
      for state: WindowsWorkbenchDisplay.ConnectionState
    ) -> BridgeDesktopStatusTone {
      connectionStatePresentation(state).tone
    }
  }
#endif
