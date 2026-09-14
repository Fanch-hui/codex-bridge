import BridgeDesktopUI
import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore

extension BridgeDesktopUIStateBuilder {
  static func selectedTask(
    from model: BridgeServiceAppModel
  ) -> BridgeDesktopTaskDetail? {
    guard let taskID = model.selectedTaskID,
      let task = model.tasks.first(where: { $0.taskID == taskID })
    else { return nil }
    let sessionTasks = WorkbenchSessionCatalog.sessionTasks(for: task, in: model.tasks)
    let session = WorkbenchSessionCatalog.sessions(tasks: sessionTasks).first
    return BridgeDesktopTaskDetail(
      taskID: task.taskID,
      sessionID: session?.sessionID ?? task.taskID,
      title: session.map {
        WorkbenchTaskTextPresentation.sessionMenuTitle(
          title: $0.title,
          turnCount: $0.turnCount
        )
      } ?? task.workbenchTitle,
      projectName: model.projectName(for: task.projectID),
      status: BridgeDesktopUIStateBuilder.displayStatus(task, model: model),
      provider: task.providerDisplayName,
      providerID: task.providerIdentifier,
      model: taskModelLabel(task, model: model),
      permissionMode: task.permissionMode,
      currentStep: task.currentStep,
      resultSummary: task.resultSummary,
      failureCode: task.failureCode,
      changedFiles: task.changedFiles,
      activity: taskActivity(task),
      conversation: conversationEntries(
        from: model.conversation,
        providerID: task.providerIdentifier
      ),
      conversationState: BridgeDesktopConversationState(
        conversation: model.conversation,
        activity: CodexActivityPresentation(
          task: task,
          activity: model.conversation?.activity ?? .idle,
          pendingUserInput: model.approvals.contains {
            $0.taskID == task.taskID && $0.kind == "user_input"
          })
      ),
      canInterrupt: TaskInspectorPresentation.canInterrupt(task),
      canStop: task.isActive,
      canSteer: TaskInspectorPresentation.canSteer(
        task,
        providerSupportsSteer: model.agentProviders.first { $0.providerID == task.providerID }?
          .supportsSteer == true
      ),
      permissionRemediation: permissionRemediation(for: task, model: model),
      turnCount: session?.turnCount ?? 1,
      canResume: canResume(task, model: model),
      canRestart: task.canRestart,
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
    from conversation: TaskConversationModel?,
    providerID: String
  ) -> [BridgeDesktopConversationEntry] {
    conversation?.entries.map {
      conversationEntry($0, providerID: providerID)
    } ?? []
  }

  private static func conversationEntry(
    _ entry: TaskConversationModel.Entry,
    providerID: String
  ) -> BridgeDesktopConversationEntry {
    let role =
      entry.role == "user"
      ? "用户" : AgentProviderPresentation.displayName(providerID)
    if entry.kind == "reasoning" {
      return BridgeDesktopConversationEntry(
        id: entry.key,
        role: role,
        text: entry.content,
        kind: entry.kind,
        displayTitle: CodexTranscriptPresentation.reasoningTitle(
          providerID: providerID,
          streaming: !entry.isFinal
        ),
        displayStatus: entry.isFinal ? "" : "进行中",
        symbol: "brain.head.profile",
        isFinal: entry.isFinal,
        status: entry.isFinal ? "final" : "streaming"
      )
    }
    if entry.kind == "tool_call" {
      let toolStatus = CodexTranscriptPresentation.resolvedToolStatus(
        providerID: providerID, name: entry.toolName, status: entry.toolStatus,
        output: entry.content
      )
      let presentation = CodexTranscriptPresentation.tool(
        providerID: providerID,
        name: entry.toolName,
        status: entry.toolStatus
      )
      return BridgeDesktopConversationEntry(
        id: entry.key,
        role: role,
        text: entry.content,
        kind: entry.kind,
        toolName: entry.toolName,
        toolStatus: toolStatus,
        toolArguments: entry.toolArguments,
        displayTitle: presentation.title,
        displayStatus: CodexTranscriptPresentation.statusLabel(toolStatus),
        symbol: presentation.systemImage,
        isFinal: entry.isFinal,
        status: entry.isFinal ? "final" : "streaming"
      )
    }
    return BridgeDesktopConversationEntry(
      id: entry.key,
      role: role,
      text: entry.content,
      kind: entry.kind,
      isFinal: entry.isFinal,
      status: entry.isFinal ? "final" : "streaming"
    )
  }

  private static func taskModelLabel(
    _ task: MCPServiceTaskSnapshot,
    model: BridgeServiceAppModel
  ) -> String? {
    let displayName: String?
    if task.isCodexTask {
      displayName = model.models.first(where: { $0.modelID == task.executionModel })?.displayName
    } else {
      displayName =
        model.agentModelOptions(for: task.providerIdentifier)
        .first(where: { $0.modelID == task.executionModel })?.displayName
    }
    let modelName = displayName ?? task.executionModel
    guard let modelName else { return nil }
    guard let effort = task.executionEffort, !effort.isEmpty else { return modelName }
    return "\(modelName) · \(BridgeDesktopPresentation.extendedReasoningTitle(effort))"
  }

}
