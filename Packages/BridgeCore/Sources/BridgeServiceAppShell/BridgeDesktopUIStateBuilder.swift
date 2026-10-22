import BridgeDesktopUI
import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore
import Foundation

@MainActor
enum BridgeDesktopUIStateBuilder {
  static func build(from model: BridgeServiceAppModel) -> BridgeDesktopUIState {
    let startedAt = ContinuousClock.now
    let navigation = BridgeDesktopNavigation.allCases.map { item in
      BridgeDesktopNavigationItem(
        navigation: item,
        badge: navigationBadge(for: item, model: model)
      )
    }
    let selected = model.navigation
    let connectionsState = connections(from: model)
    let state = BridgeDesktopUIState(
      navigation: navigation,
      selectedNavigation: selected.desktopNavigation,
      connectionLabel: model.connectionState.label,
      connectionTone: connectionTone(for: model.connectionState),
      isRefreshing: model.isRefreshing,
      overview: overview(from: model, connections: connectionsState),
      workbench: workbench(from: model),
      projects: projects(from: model),
      logs: logs(from: model),
      connections: connectionsState,
      settings: settings(from: model),
      appUpdate: model.appUpdateState
    )
    ConversationPerformanceRecorder.shared.record(
      ConversationPerformanceSample(
        stage: .desktopStateBuild,
        duration: startedAt.duration(to: ContinuousClock.now),
        entryCount: model.conversation?.entries.count ?? 0
      )
    )
    return state
  }

  private static func overview(
    from model: BridgeServiceAppModel, connections: BridgeDesktopConnectionsState
  ) -> BridgeDesktopOverviewState {
    let agentStates = model.agentInstallations.map { installation in
      (
        installation.displayName,
        BridgeDesktopAgentAvailability.resolve(
          providerID: installation.providerID, enabled: installation.isEnabled,
          availability: installation.availability,
          desktop: model.deepSeekDesktopStates[installation.installationID])
      )
    }
    let enabledAgents = agentStates.filter { $0.1 == .available }.count
    let reconnectSummary = ProjectAgentPresentation.reconnectSummary(
      names: agentStates.compactMap { $0.1 == .requiresReconnect ? $0.0 : nil })
    let clientConnections = BridgeDesktopOverviewPresentation.clientConnections(
      clients: connections.clients, serviceAvailable: model.connectionState == .connected,
      localMCPReady: model.serviceStatus?.status.mcpState == "ready",
      tunnel: connections.tunnel, geminiCloud: connections.geminiCloud)

    return BridgeDesktopOverviewState(
      title: "概览",
      subtitle: "",
      notices: notices(from: model, clientConnections: clientConnections),
      metrics: [],
      services: services(
        from: model,
        enabledAgents: enabledAgents,
        reconnectSummary: reconnectSummary
      ),
      serviceActions: [],
      recentTasks: model.tasks.prefix(4).map { task in
        BridgeDesktopRecentTask(
          id: task.taskID,
          title: task.workbenchTitle,
          projectName: model.projectName(for: task.projectID),
          source: task.sourceDisplayName,
          status: taskStatusLabel(task.status),
          updatedAt: task.updatedAt
        )
      },
      lastUpdatedAt: model.lastRefreshAt.map { $0.formatted(.iso8601) },
      clientConnections: clientConnections,
      onboardingSteps: BridgeDesktopOverviewPresentation.onboardingSteps(
        hasProjects: !model.projects.isEmpty,
        hasConfiguredClient: clientConnections.contains { $0.tone == .success }
          || (connections.geminiCloud?.enabled == true
            && connections.geminiCloud?.lifecycle == "configured"
            && connections.clients.contains { $0.clientID == "google.gemini" && $0.enabled })
      )
    )
  }

  private static func services(
    from model: BridgeServiceAppModel,
    enabledAgents: Int,
    reconnectSummary: String?
  ) -> [BridgeDesktopServiceRow] {
    [
      BridgeDesktopServiceRow(
        id: "service",
        title: "后台常驻 Service",
        value: model.connectionState.label,
        symbol: model.connectionState.symbol,
        tone: connectionTone(for: model.connectionState),
        destination: .connections
      ),
      mcpRow(from: model),
      tunnelRow(from: model),
      BridgeDesktopServiceRow(
        id: "local-agents",
        title: "本机 Agent 引擎",
        value: reconnectSummary
          ?? "\(enabledAgents) 个可用 / 共 \(model.agentInstallations.count) 个",
        symbol: reconnectSummary == nil ? "cpu.fill" : "exclamationmark.triangle.fill",
        tone: reconnectSummary == nil
          ? (enabledAgents > 0 ? .success : .neutral)
          : .warning,
        destination: .connections
      ),
    ]
  }

  private static func mcpRow(from model: BridgeServiceAppModel) -> BridgeDesktopServiceRow {
    let value = model.serviceStatus?.status.mcpState ?? "未知"
    let ready = value == "ready"
    return BridgeDesktopServiceRow(
      id: "local-mcp",
      title: "本地 MCP 通道",
      value: value,
      symbol: ready ? "checkmark.circle.fill" : "circle.dashed",
      tone: ready ? .success : .neutral,
      destination: .connections
    )
  }

  private static func tunnelRow(from model: BridgeServiceAppModel) -> BridgeDesktopServiceRow {
    guard let tunnel = model.serviceStatus?.tunnel else {
      return BridgeDesktopServiceRow(
        id: "secure-tunnel",
        title: "远程 Secure Tunnel",
        value: "未配置",
        symbol: "link",
        tone: .neutral,
        destination: .connections
      )
    }
    let lifecycle = tunnel.lifecycle.isEmpty ? "未知" : tunnel.lifecycle
    if lifecycle == "ready" {
      return BridgeDesktopServiceRow(
        id: "secure-tunnel",
        title: "远程 Secure Tunnel",
        value: lifecycle,
        symbol: "checkmark.circle.fill",
        tone: .success,
        destination: .connections
      )
    }
    if tunnel.actionRequired {
      return BridgeDesktopServiceRow(
        id: "secure-tunnel",
        title: "远程 Secure Tunnel",
        value: lifecycle,
        symbol: "shield.lefthalf.filled",
        tone: .warning,
        destination: .connections
      )
    }
    return BridgeDesktopServiceRow(
      id: "secure-tunnel",
      title: "远程 Secure Tunnel",
      value: lifecycle,
      symbol: tunnel.enabled ? "link" : "circle.dashed",
      tone: tunnel.enabled ? .running : .neutral,
      destination: .connections
    )
  }

  private static func notices(
    from model: BridgeServiceAppModel, clientConnections: [BridgeDesktopServiceRow]
  ) -> [BridgeDesktopNotice] {
    var result: [BridgeDesktopNotice] = []
    if model.registrationStatus == .requiresApproval {
      result.append(
        BridgeDesktopNotice(
          id: "service-approval",
          title: "需要批准后台项目",
          message: "请在系统设置中批准 Codex Bridge 后台 LaunchAgent 项目。",
          symbol: "shield.lefthalf.filled",
          tone: .warning,
          command: .openSystemSettings
        )
      )
    }
    if model.connectionState == .unavailable {
      result.append(
        BridgeDesktopNotice(
          id: "service-unavailable", title: "后台服务不可用",
          message: "打开诊断检查后台服务状态。", symbol: "exclamationmark.triangle.fill",
          tone: .error, destination: .settings))
    }
    let approvalCount = model.approvals.count + model.directApprovals.count
    if approvalCount > 0 {
      result.append(
        BridgeDesktopNotice(
          id: "local-approvals",
          title: "待处理本机审批",
          message: "当前有 \(approvalCount) 个远程任务或执行器操作等待你本机确认或拒绝。",
          symbol: "shield.lefthalf.filled",
          tone: .warning,
          destination: .workbench
        )
      )
    }
    result += BridgeDesktopOverviewPresentation.clientNotices(
      connections: clientConnections, serviceAvailable: model.connectionState == .connected)
    result += model.agentInstallations.compactMap { installation in
      let availability = BridgeDesktopAgentAvailability.resolve(
        providerID: installation.providerID, enabled: installation.isEnabled,
        availability: installation.availability,
        desktop: model.deepSeekDesktopStates[installation.installationID])
      return BridgeDesktopOverviewPresentation.agentNotice(
        installationID: installation.installationID, providerID: installation.providerID,
        displayName: installation.displayName, availability: installation.availability,
        requiresReconnect: availability == .requiresReconnect)
    }
    result += BridgeDesktopOverviewPresentation.setupNotices(
      operations: model.agentSetupOperations.map(agentSetupState))
    return result
  }

  private static func navigationBadge(
    for navigation: BridgeDesktopNavigation,
    model: BridgeServiceAppModel
  ) -> Int? {
    switch navigation {
    case .workbench:
      let approvalCount = model.approvals.count + model.directApprovals.count
      if approvalCount > 0 { return approvalCount }
      return model.runningTaskCount > 0 ? model.runningTaskCount : nil
    case .projects:
      return model.projects.isEmpty ? nil : model.projects.count
    default:
      return nil
    }
  }

  static func connectionTone(
    for state: BridgeServiceConnectionState
  ) -> BridgeDesktopStatusTone {
    switch state {
    case .connected: .success
    case .registering, .connecting: .running
    case .requiresApproval: .warning
    case .idle: .neutral
    case .unavailable: .error
    }
  }

  static func taskStatusLabel(_ status: String) -> String {
    WorkbenchTaskTextPresentation.statusLabel(status)
  }

}

extension BridgeServiceNavigation {
  fileprivate var desktopNavigation: BridgeDesktopNavigation {
    switch self {
    case .overview: .overview
    case .workbench: .workbench
    case .projects: .projects
    case .logs: .logs
    case .connections: .connections
    case .settings: .settings
    }
  }
}
