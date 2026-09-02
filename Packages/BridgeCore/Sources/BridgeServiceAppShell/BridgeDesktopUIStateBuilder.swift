import BridgeDesktopUI
import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore
import Foundation

@MainActor
enum BridgeDesktopUIStateBuilder {
  static func build(from model: BridgeServiceAppModel) -> BridgeDesktopUIState {
    let navigation = BridgeDesktopNavigation.allCases.map { item in
      BridgeDesktopNavigationItem(
        navigation: item,
        badge: navigationBadge(for: item, model: model)
      )
    }
    let selected = model.navigation
    return BridgeDesktopUIState(
      navigation: navigation,
      selectedNavigation: selected.desktopNavigation,
      connectionLabel: model.connectionState.label,
      connectionTone: connectionTone(for: model.connectionState),
      isRefreshing: model.isRefreshing,
      overview: overview(from: model),
      workbench: workbench(from: model),
      projects: projects(from: model),
      logs: logs(from: model),
      connections: connections(from: model),
      settings: settings(from: model)
    )
  }

  private static func overview(from model: BridgeServiceAppModel) -> BridgeDesktopOverviewState {
    let enabledAgents = model.agentInstallations.filter {
      $0.isEnabled && $0.availability == "available"
    }.count
    let metrics = [
      BridgeDesktopMetric(
        id: "running-tasks",
        title: "运行中任务",
        value: String(model.runningTaskCount),
        symbol: "bolt.fill",
        subtitle: model.runningTaskCount > 0 ? "点击进入工作台" : "当前空闲",
        tone: model.runningTaskCount > 0 ? .running : .neutral,
        destination: .workbench
      ),
      BridgeDesktopMetric(
        id: "pending-approvals",
        title: "待审批项",
        value: String(model.approvals.count),
        symbol: "shield.lefthalf.filled",
        subtitle: model.approvals.isEmpty ? "无阻断事项" : "点击立即处理审批",
        tone: model.approvals.isEmpty ? .neutral : .warning,
        destination: .workbench
      ),
      BridgeDesktopMetric(
        id: "registered-projects",
        title: "注册项目",
        value: String(model.projects.count),
        symbol: "folder.fill",
        subtitle: "管理本地目录",
        tone: .running,
        destination: .projects
      ),
      BridgeDesktopMetric(
        id: "local-agents",
        title: "本机 Agent",
        value: String(enabledAgents),
        symbol: "cpu.fill",
        subtitle: model.agentInstallations.isEmpty
          ? "未连接外部 Agent"
          : "共 \(model.agentInstallations.count) 个已登记",
        tone: enabledAgents > 0 ? .success : .neutral,
        destination: .connections
      ),
      BridgeDesktopMetric(
        id: "total-tasks",
        title: "任务总数",
        value: String(model.tasks.count),
        symbol: "list.bullet.rectangle",
        subtitle: lastRefreshSubtitle(for: model),
        tone: .neutral,
        destination: .workbench
      ),
    ]

    return BridgeDesktopOverviewState(
      title: "概览",
      subtitle: "全景监控后台 Service、本地 MCP、Secure Tunnel 与任务执行状态。",
      notices: notices(from: model),
      metrics: metrics,
      services: services(from: model, enabledAgents: enabledAgents),
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
      lastUpdatedAt: model.lastRefreshAt.map { $0.formatted(.iso8601) }
    )
  }

  private static func services(
    from model: BridgeServiceAppModel,
    enabledAgents: Int
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
        value: "\(enabledAgents) 个可用 / 共 \(model.agentInstallations.count) 个",
        symbol: "cpu.fill",
        tone: enabledAgents > 0 ? .success : .neutral,
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

  private static func notices(from model: BridgeServiceAppModel) -> [BridgeDesktopNotice] {
    var result: [BridgeDesktopNotice] = []
    if model.registrationStatus == .requiresApproval {
      result.append(
        BridgeDesktopNotice(
          id: "service-approval",
          title: "需要批准后台项目",
          message: "请在系统设置中批准 Codex Bridge 后台 LaunchAgent 项目。",
          symbol: "shield.lefthalf.filled",
          tone: .warning,
          destination: .connections
        )
      )
    }
    if !model.approvals.isEmpty {
      result.append(
        BridgeDesktopNotice(
          id: "local-approvals",
          title: "待处理本机审批",
          message: "当前有 \(model.approvals.count) 个远程任务或执行器操作等待你本机确认或拒绝。",
          symbol: "shield.lefthalf.filled",
          tone: .warning,
          destination: .workbench
        )
      )
    }
    return result
  }

  private static func navigationBadge(
    for navigation: BridgeDesktopNavigation,
    model: BridgeServiceAppModel
  ) -> Int? {
    switch navigation {
    case .workbench:
      if !model.approvals.isEmpty { return model.approvals.count }
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
    switch status {
    case "awaiting_local_approval": "等待本机批准"
    case "starting": "正在启动"
    case "running": "运行中"
    case "waiting_for_codex_approval": "等待 Codex 审批"
    case "completed": "已完成"
    case "failed": "失败"
    case "interrupted": "已中断"
    default: status
    }
  }

  private static func lastRefreshSubtitle(for model: BridgeServiceAppModel) -> String {
    guard let lastRefreshAt = model.lastRefreshAt else { return "任务历史" }
    return "更新于 " + lastRefreshAt.formatted(date: .omitted, time: .standard)
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
