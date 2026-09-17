import AppKit
import BridgeDesktopUI
import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore

extension BridgeDesktopCommandRouter {
  static func handleWorkbench(
    _ envelope: BridgeDesktopCommandEnvelope,
    model: BridgeServiceAppModel
  ) {
    let payload = envelope.payload
    switch envelope.command {
    case .browserBack:
      guard model.isChatBrowserEnabled, model.chatWebView?.canGoBack == true else { return }
      model.chatWebView?.goBack()
    case .browserForward:
      guard model.isChatBrowserEnabled, model.chatWebView?.canGoForward == true else { return }
      model.chatWebView?.goForward()
    case .browserReload:
      guard model.isChatBrowserEnabled else { return }
      model.reloadChatBrowser()
    case .setBrowserEnabled:
      guard let enabled = payload.enabled else { return }
      model.isChatBrowserEnabled = enabled
      if !enabled { model.chatBrowserViewport = nil }
    case .openBrowserExternally:
      openBrowserExternally(model)
    case .loadEarlierConversation:
      loadEarlier(payload.taskID, model: model)
    case .refreshConversation:
      refreshConversation(payload.taskID, model: model)
    case .setWorkbenchPermissionMode:
      guard let mode = validatedID(payload.mode, maximumBytes: 64),
        mode == "read-only" || mode == "workspace-write",
        connected(model)
      else { return }
      model.setWorkbenchPermissionMode(mode)
    case .selectTask:
      guard let taskID = validatedID(payload.taskID),
        model.tasks.contains(where: { $0.taskID == taskID })
      else { return }
      model.openTask(taskID)
      model.selection = .workbench
    case .refreshTasks:
      model.refresh()
    case .interruptTask:
      guard let task = task(payload.taskID, in: model),
        connected(model),
        TaskInspectorPresentation.canInterrupt(task)
      else { return }
      model.interruptTask(task)
    case .stopTask:
      guard let taskID = validatedID(payload.taskID),
        connected(model),
        model.tasks.contains(where: { $0.taskID == taskID && $0.isActive })
      else { return }
      model.stopTask(taskID)
    case .deleteTask:
      guard let taskID = validatedID(payload.taskID),
        connected(model),
        model.tasks.contains(where: { $0.taskID == taskID && $0.isTerminal })
      else { return }
      model.deleteTask(taskID)
    case .deleteSession:
      guard let selectedTask = task(payload.taskID, in: model), connected(model) else { return }
      let sessionTasks = WorkbenchSessionCatalog.sessionTasks(for: selectedTask, in: model.tasks)
      guard !sessionTasks.isEmpty, sessionTasks.allSatisfy({ $0.isTerminal }) else { return }
      model.deleteSession(
        selectedTask.effectiveSessionID ?? selectedTask.taskID,
        inProject: selectedTask.projectID,
        providerID: selectedTask.providerIdentifier
      )
    case .steerTask:
      steer(payload, model: model)
    case .resumeTask:
      guard let selectedTask = task(payload.taskID, in: model), connected(model) else { return }
      let supportsContinuation = TaskInspectorPresentation.supportsSessionContinuation(
        for: selectedTask, providers: model.agentProviders, installations: model.agentInstallations
      )
      guard
        TaskInspectorPresentation.canResume(
          selectedTask,
          providerSupportsSessionContinuation: supportsContinuation
        )
      else { return }
      model.resumeTask(selectedTask, prompt: payload.input)
    case .restartTask:
      guard let selectedTask = task(payload.taskID, in: model),
        connected(model), selectedTask.canRestart
      else { return }
      model.restartTask(selectedTask)
    case .resolveApproval:
      resolveApproval(payload, model: model)
    case .resolveDirectApproval:
      resolveDirectApproval(payload, model: model)
    default:
      return
    }
  }

  private static func task(
    _ taskID: String?,
    in model: BridgeServiceAppModel
  ) -> MCPServiceTaskSnapshot? {
    guard let taskID = validatedID(taskID) else { return nil }
    return model.tasks.first { $0.taskID == taskID }
  }

  private static func openBrowserExternally(_ model: BridgeServiceAppModel) {
    let candidate = model.chatWebView?.url ?? model.chatBrowserResumeURL
    guard let host = candidate.host?.lowercased(),
      candidate.scheme?.lowercased() == "https",
      host == "chatgpt.com" || host.hasSuffix(".chatgpt.com")
    else { return }
    NSWorkspace.shared.open(candidate)
  }

  private static func loadEarlier(_ taskID: String?, model: BridgeServiceAppModel) {
    guard let taskID = validatedID(taskID),
      let conversation = model.conversation,
      conversation.taskID == taskID,
      conversation.canLoadEarlier
    else { return }
    Task { await conversation.loadEarlier() }
  }

  private static func refreshConversation(_ taskID: String?, model: BridgeServiceAppModel) {
    guard let taskID = validatedID(taskID),
      let conversation = model.conversation,
      conversation.taskID == taskID
    else { return }
    model.refreshConversation(taskID: taskID)
  }

  private static func steer(
    _ payload: BridgeDesktopCommandPayload,
    model: BridgeServiceAppModel
  ) {
    guard let task = task(payload.taskID, in: model), connected(model),
      TaskInspectorPresentation.canSteer(
        task,
        providerSupportsSteer: task.isCodexTask
          || task.providerID.flatMap { providerID in
            model.agentProviders.first(where: { $0.providerID == providerID })?.supportsSteer
          } == true
      ),
      let input = validatedText(payload.input, maximumBytes: IPCTaskSteerRequest.maximumInputBytes),
      TaskInspectorPresentation.steerValidationMessage(input) == nil
    else { return }
    let mode = MCPTaskSteerMode(rawValue: payload.mode ?? "queued") ?? .queued
    if mode == .interruptCurrentThenContinue {
      let supportsImmediate =
        task.installationID.flatMap { installationID in
          model.agentInstallations.first(where: { $0.installationID == installationID })
        }?.effectiveCapabilities.contains("lifecycle.steer_interrupt_and_continue") == true
      guard supportsImmediate else { return }
    }
    model.steerTask(task, input: input, mode: mode)
  }

  private static func resolveApproval(
    _ payload: BridgeDesktopCommandPayload,
    model: BridgeServiceAppModel
  ) {
    guard let approvalID = validatedID(payload.approvalID),
      let approval = model.approvals.first(where: { $0.approvalID == approvalID }),
      connected(model),
      payload.taskID == nil || payload.taskID == approval.taskID,
      let decision = validatedID(payload.decision, maximumBytes: 128)
    else { return }
    let answers: [String: [String]]?
    if approval.kind == "user_input" {
      guard let input = validatedText(payload.input, maximumBytes: 64 * 1_024),
        let data = input.data(using: .utf8),
        let decoded = try? JSONDecoder().decode([String: [String]].self, from: data),
        !decoded.isEmpty
      else { return }
      answers = decoded
    } else {
      answers = nil
    }
    let projectID = model.tasks.first(where: { $0.taskID == approval.taskID })?.projectID
    let presentation = ApprovalPresentation.task(
      approval,
      projectName: projectID.map { model.projectName(for: $0) }
    )
    guard decision == "deny" || presentation.allowDecisions.contains(decision) else { return }
    let oneTimeToolAutoApproval = payload.oneTimeToolAutoApproval == true
    if oneTimeToolAutoApproval {
      guard decision == "allow", approval.kind == "task_start",
        approval.oneTimeToolAutoApprovalAvailable == true,
        payload.confirmed == true
      else { return }
    }
    model.resolveApproval(
      approval,
      decision: decision,
      oneTimeToolAutoApproval: oneTimeToolAutoApproval,
      answers: answers
    )
  }

  private static func resolveDirectApproval(
    _ payload: BridgeDesktopCommandPayload,
    model: BridgeServiceAppModel
  ) {
    guard let approvalID = validatedID(payload.approvalID),
      let approval = model.directApprovals.first(where: { $0.approvalID == approvalID }),
      connected(model),
      let decision = validatedID(payload.decision, maximumBytes: 32),
      decision == "allow" || decision == "deny"
    else { return }
    model.resolveDirectApproval(approval, allow: decision == "allow")
  }
}
