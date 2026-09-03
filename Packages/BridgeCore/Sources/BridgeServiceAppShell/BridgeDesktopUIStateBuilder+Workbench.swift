import BridgeDesktopUI
import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore

extension BridgeDesktopUIStateBuilder {
  static func workbench(from model: BridgeServiceAppModel) -> BridgeDesktopWorkbenchState {
    let (projectStatus, projectStatusTone) = projectStatus(from: model)
    return BridgeDesktopWorkbenchState(
      header: BridgeDesktopPageHeader(
        title: "工作台",
        subtitle: "在本机 ChatGPT 工作区旁查看任务、审批与实时执行状态。",
        symbol: BridgeServiceNavigation.workbench.symbol
      ),
      projects: model.projects.map {
        BridgeDesktopChoice(id: $0.projectID, title: $0.name, detail: $0.gitState)
      },
      selectedProjectID: model.selectedProjectID,
      permissionMode: model.workbenchPermissionMode,
      permissionOptions: permissionOptions,
      tasks: model.tasks.map { task in taskRow(task, model: model) },
      selectedTaskID: model.selectedTaskID,
      selectedTask: selectedTask(from: model),
      approvals: approvals(from: model),
      steerModes: steerModes(from: model),
      browser: browserSlot(from: model),
      projectStatus: projectStatus,
      projectStatusTone: projectStatusTone,
      engineStatus: engineStatus(from: model)
    )
  }

  private static func projectStatus(
    from model: BridgeServiceAppModel
  ) -> (String, String) {
    if let taskID = model.selectedTaskID,
      let task = model.tasks.first(where: { $0.taskID == taskID })
    {
      if task.isRunning {
        return ("运行中", "running")
      }
      return (taskStatusLabel(task.status), statusTone(task.status))
    }
    if model.runningTaskCount > 0 {
      return ("运行中", "running")
    }
    return ("就绪", "success")
  }

  private static func statusTone(_ status: String) -> String {
    switch status {
    case "running", "starting": "running"
    case "completed": "success"
    case "failed": "error"
    case "awaiting_local_approval", "waiting_for_codex_approval": "warning"
    default: "neutral"
    }
  }

  private static func engineStatus(from model: BridgeServiceAppModel) -> String {
    guard model.connectionState == .connected else {
      return model.connectionState.label
    }
    let task =
      model.selectedTaskID.flatMap { id in
        model.tasks.first(where: { $0.taskID == id })
      } ?? model.tasks.first(where: { $0.isRunning })
    return CodexActivityPresentation(
      task: task,
      activity: model.conversation?.activity ?? .idle
    ).statusText
  }

  private static let permissionOptions = [
    BridgeDesktopChoice(id: "read-only", title: "只读", detail: "不写入项目文件"),
    BridgeDesktopChoice(id: "workspace-write", title: "工作区可写", detail: "遵循项目权限与本机批准"),
  ]

  private static func steerModes(
    from model: BridgeServiceAppModel
  ) -> [BridgeDesktopChoice] {
    var result = [BridgeDesktopChoice(id: "queued", title: "当前轮结束后继续")]
    guard let taskID = model.selectedTaskID,
      let installationID = model.tasks.first(where: { $0.taskID == taskID })?.installationID,
      model.agentInstallations.first(where: { $0.installationID == installationID })?
        .effectiveCapabilities.contains("lifecycle.steer_interrupt_and_continue") == true
    else { return result }
    result.append(
      BridgeDesktopChoice(
        id: "interrupt-current-then-continue",
        title: "立即纠偏当前轮"
      )
    )
    return result
  }

  private static func taskRow(
    _ task: MCPServiceTaskSnapshot,
    model: BridgeServiceAppModel
  ) -> BridgeDesktopTaskRow {
    let providerCanSteer =
      task.providerID.flatMap { providerID in
        model.agentProviders.first(where: { $0.providerID == providerID })?.supportsSteer
      } == true
    return BridgeDesktopTaskRow(
      taskID: task.taskID,
      title: task.workbenchTitle,
      projectID: task.projectID,
      projectName: model.projectName(for: task.projectID),
      source: task.sourceDisplayName,
      provider: task.providerDisplayName,
      status: taskStatusLabel(task.status),
      updatedAt: task.updatedAt,
      selected: task.taskID == model.selectedTaskID,
      isRunning: task.isRunning,
      isActive: task.isActive,
      canInterrupt: TaskInspectorPresentation.canInterrupt(task),
      canStop: task.isActive,
      canSteer: TaskInspectorPresentation.canSteer(
        task,
        providerSupportsSteer: providerCanSteer
      ),
      canDelete: task.isTerminal
    )
  }

  private static func selectedTask(
    from model: BridgeServiceAppModel
  ) -> BridgeDesktopTaskDetail? {
    guard let taskID = model.selectedTaskID,
      let task = model.tasks.first(where: { $0.taskID == taskID })
    else { return nil }
    return BridgeDesktopTaskDetail(
      taskID: task.taskID,
      title: task.workbenchTitle,
      projectName: model.projectName(for: task.projectID),
      status: taskStatusLabel(task.status),
      provider: task.providerDisplayName,
      model: task.executionModel,
      permissionMode: task.permissionMode,
      currentStep: task.currentStep,
      resultSummary: task.resultSummary,
      failureCode: task.failureCode,
      changedFiles: task.changedFiles,
      activity: taskActivity(task),
      conversation: conversationEntries(from: model.conversation),
      updatedAt: task.updatedAt
    )
  }

  private static func taskActivity(_ task: MCPServiceTaskSnapshot) -> [BridgeDesktopActivityRow] {
    task.recentActivity.map {
      BridgeDesktopActivityRow(
        id: "\(task.taskID)-activity-\($0.sequence)",
        sequence: $0.sequence,
        kind: $0.kind,
        summary: $0.summary,
        occurredAt: $0.occurredAt
      )
    }
  }

  private static func conversationEntries(
    from conversation: TaskConversationModel?
  ) -> [BridgeDesktopConversationEntry] {
    conversation?.entries.map {
      let role = $0.role == "user" ? "用户" : "Agent"
      return BridgeDesktopConversationEntry(
        id: $0.key,
        role: role,
        text: $0.content,
        kind: $0.kind,
        toolName: $0.toolName,
        toolStatus: $0.toolStatus,
        toolArguments: $0.toolArguments,
        isFinal: $0.isFinal,
        status: $0.isFinal ? "final" : "streaming"
      )
    } ?? []
  }

  private static func approvals(
    from model: BridgeServiceAppModel
  ) -> [BridgeDesktopApprovalRow] {
    let taskRows = model.approvals.map { approval in
      let projectID = model.tasks.first(where: { $0.taskID == approval.taskID })?.projectID
      let presentation = ApprovalPresentation.task(
        approval,
        projectName: projectID.map { model.projectName(for: $0) }
      )
      return BridgeDesktopApprovalRow(
        approvalID: approval.approvalID,
        taskID: approval.taskID,
        projectID: projectID,
        kind: approval.kind,
        title: approval.title,
        summary: approval.summary,
        displayCommand: approval.displayCommand,
        relativePaths: approval.relativePaths,
        reason: approval.reason,
        decisionOptions: (approval.decisionOptions ?? ["allow"]) + ["deny"],
        canAllow: !presentation.allowDecisions.isEmpty,
        canDeny: true,
        resolving: model.isResolvingApproval(approval)
      )
    }
    let directRows = model.directApprovals.map { approval in
      let presentation = ApprovalPresentation.direct(
        approval,
        projectName: model.projectName(for: approval.projectID)
      )
      return BridgeDesktopApprovalRow(
        approvalID: approval.approvalID,
        projectID: approval.projectID,
        isDirect: true,
        kind: approval.kind,
        title: "Direct 操作审批",
        summary: approval.summary,
        decisionOptions: presentation.allowDecisions + ["deny"],
        canAllow: true,
        canDeny: true,
        resolving: model.isResolvingDirectApproval(approval)
      )
    }
    return taskRows + directRows
  }

  private static func browserSlot(
    from model: BridgeServiceAppModel
  ) -> BridgeDesktopBrowserSlot {
    let visible = model.navigation == .workbench && model.isChatBrowserEnabled
    let status =
      model.isChatBrowserEnabled
      ? (model.chatWebView?.url?.absoluteString ?? "由宿主加载真实 ChatGPT 工作区")
      : "内置浏览器已关闭"
    return BridgeDesktopBrowserSlot(
      visible: visible,
      enabled: model.isChatBrowserEnabled,
      status: status,
      canToggle: true,
      canOpenExternally: true,
      canGoBack: model.chatWebView?.canGoBack == true,
      canGoForward: model.chatWebView?.canGoForward == true,
      canReload: model.isChatBrowserEnabled,
      canLoadEarlierConversation: model.conversation?.canLoadEarlier == true
    )
  }
}
