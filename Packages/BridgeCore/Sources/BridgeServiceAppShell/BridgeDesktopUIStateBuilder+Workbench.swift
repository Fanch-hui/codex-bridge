import BridgeDesktopUI
import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore

extension BridgeDesktopUIStateBuilder {
  static func workbench(from model: BridgeServiceAppModel) -> BridgeDesktopWorkbenchState {
    let (projectStatus, projectStatusTone) = projectStatus(from: model)
    let projectTasks = model.tasks.filter {
      model.selectedProjectID == nil || $0.projectID == model.selectedProjectID
    }
    let sessions = WorkbenchSessionCatalog.sessions(tasks: projectTasks)
      .sorted { $0.latestTask.updatedAt > $1.latestTask.updatedAt }
    return BridgeDesktopWorkbenchState(
      header: BridgeDesktopPageHeader(
        title: "工作台",
        subtitle: "在本机 ChatGPT 工作区旁查看任务、审批与实时执行状态。",
        symbol: BridgeServiceNavigation.workbench.symbol
      ),
      projects: model.projects.map {
        BridgeDesktopChoice(
          id: $0.projectID, title: $0.name,
          detail: ProjectAgentPresentation.gitStateLabel($0.gitState))
      },
      selectedProjectID: model.selectedProjectID,
      permissionMode: model.workbenchPermissionMode,
      permissionOptions: permissionOptions,
      tasks: sessions.map { session in taskRow(session, model: model) },
      selectedTaskID: model.selectedTaskID,
      selectedTask: selectedTask(from: model),
      history: threadHistory(from: model),
      approvals: approvals(from: model),
      steerModes: steerModes(from: model),
      browser: browserSlot(from: model),
      projectStatus: projectStatus,
      projectStatusTone: projectStatusTone,
      engineStatus: engineStatus(from: model),
      modelCount: model.models.count,
      canRefreshModels: !model.isRefreshing,
      isRefreshingModels: model.isRefreshing,
      modelError: model.modelCatalogError
    )
  }

  private static func projectStatus(
    from model: BridgeServiceAppModel
  ) -> (String, String) {
    if let taskID = model.selectedTaskID,
      let task = model.tasks.first(where: { $0.taskID == taskID })
    {
      if hasPendingUserInput(task, model: model) {
        return ("等待回答", "warning")
      }
      if task.isRunning {
        return ("运行中", "running")
      }
      let status = displayStatus(task, model: model)
      let tone = hasPendingUserInput(task, model: model) ? "warning" : statusTone(task.status)
      return (status, tone)
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
    case "等待回答", "awaiting_local_approval", "waiting_for_codex_approval": "warning"
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
      activity: model.conversation?.activity ?? .idle,
      pendingUserInput: task.map { hasPendingUserInput($0, model: model) } ?? false
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
    _ session: WorkbenchSessionItem,
    model: BridgeServiceAppModel
  ) -> BridgeDesktopTaskRow {
    let task = session.latestTask
    let providerCanSteer =
      task.providerID.flatMap { providerID in
        model.agentProviders.first(where: { $0.providerID == providerID })?.supportsSteer
      } == true
    return BridgeDesktopTaskRow(
      taskID: task.taskID,
      sessionID: session.sessionID,
      title: WorkbenchTaskTextPresentation.sessionMenuTitle(
        title: session.title,
        turnCount: session.turnCount
      ),
      projectID: task.projectID,
      projectName: model.projectName(for: task.projectID),
      source: task.sourceDisplayName,
      provider: task.providerDisplayName,
      providerID: task.providerIdentifier,
      status: displayStatus(task, model: model),
      updatedAt: task.updatedAt,
      turnCount: session.turnCount,
      selected: session.tasks.contains(where: { $0.taskID == model.selectedTaskID }),
      isRunning: task.isRunning,
      isActive: task.isActive,
      canInterrupt: TaskInspectorPresentation.canInterrupt(task),
      canStop: task.isActive,
      canSteer: TaskInspectorPresentation.canSteer(
        task,
        providerSupportsSteer: providerCanSteer
      ),
      canResume: canResume(task, model: model),
      canRestart: task.canRestart,
      canDelete: session.tasks.allSatisfy { $0.isTerminal }
    )
  }

  static func canResume(
    _ task: MCPServiceTaskSnapshot,
    model: BridgeServiceAppModel
  ) -> Bool {
    let supportsContinuation = TaskInspectorPresentation.supportsSessionContinuation(
      for: task, providers: model.agentProviders, installations: model.agentInstallations
    )
    return TaskInspectorPresentation.canResume(
      task,
      providerSupportsSessionContinuation: supportsContinuation
    )
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
        decisionOptions: presentation.allowDecisions + ["deny"],
        canAllow: !presentation.allowDecisions.isEmpty,
        canDeny: true,
        resolving: model.isResolvingApproval(approval),
        oneTimeToolAutoApprovalAvailable: approval.oneTimeToolAutoApprovalAvailable,
        questions: approval.questions?.map(desktopQuestion) ?? []
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

  private static func hasPendingUserInput(
    _ task: MCPServiceTaskSnapshot,
    model: BridgeServiceAppModel
  ) -> Bool {
    model.approvals.contains { $0.taskID == task.taskID && $0.kind == "user_input" }
  }

  static func displayStatus(
    _ task: MCPServiceTaskSnapshot,
    model: BridgeServiceAppModel
  ) -> String {
    hasPendingUserInput(task, model: model) ? "等待回答" : taskStatusLabel(task.status)
  }

  private static func desktopQuestion(
    _ question: IPCUserInputQuestion
  ) -> BridgeDesktopApprovalQuestion {
    BridgeDesktopApprovalQuestion(
      id: question.id,
      header: question.header,
      question: question.question,
      isOther: question.isOther,
      isSecret: question.isSecret,
      options: question.options.map {
        BridgeDesktopApprovalOption(label: $0.label, description: $0.description)
      }
    )
  }

  static func permissionRemediation(
    for task: MCPServiceTaskSnapshot,
    model: BridgeServiceAppModel
  ) -> BridgeDesktopPermissionRemediationState? {
    guard task.providerID == "antigravity",
      task.failureCode == "antigravity_permission_denied",
      let entry = model.conversation?.entries.last(where: {
        $0.kind == "tool_call" && $0.toolStatus == "declined"
      })
    else { return nil }
    let response = model.agentPermissionRemediations[task.taskID].flatMap {
      $0.messageKey == entry.key ? $0 : nil
    }
    return BridgeDesktopPermissionRemediationState(
      messageKey: entry.key,
      installationID: response?.installationID,
      candidateID: response?.candidateID,
      action: response?.action,
      target: response?.target,
      displayRule: response?.displayRule,
      requiresConfirmation: response?.requiresConfirmation ?? false,
      isLoading: model.agentPermissionRemediationLoadingTaskIDs.contains(task.taskID),
      isApplying: model.agentPermissionRemediationApplyingTaskIDs.contains(task.taskID),
      didApply: model.agentPermissionRemediationAppliedTaskIDs.contains(task.taskID),
      errorMessage: model.agentPermissionRemediationErrors[task.taskID]
    )
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
      url: model.chatWebView?.url?.absoluteString ?? model.chatBrowserResumeURL.absoluteString,
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
