#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore

  extension WindowsWorkbenchModel {
    static func sessionItem(
      _ session: WorkbenchSessionItem,
      projectName: String,
      selectedTaskID: String?,
      canSteer: Bool,
      canResume: Bool,
      pendingUserInput: Bool = false
    ) -> BridgeDesktopTaskRow {
      let task = session.latestTask
      return BridgeDesktopTaskRow(
        taskID: task.taskID,
        sessionID: session.sessionID,
        title: WorkbenchTaskTextPresentation.sessionMenuTitle(
          title: session.title,
          turnCount: session.turnCount
        ),
        projectID: task.projectID,
        projectName: projectName,
        source: task.sourceDisplayName,
        provider: task.providerDisplayName,
        providerID: task.providerIdentifier,
        status: desktopStatusLabel(task, pendingUserInput: pendingUserInput),
        updatedAt: task.updatedAt,
        turnCount: session.turnCount,
        selected: session.tasks.contains(where: { $0.taskID == selectedTaskID }),
        isRunning: task.isRunning,
        isActive: task.isActive,
        canInterrupt: TaskInspectorPresentation.canInterrupt(task),
        canStop: task.isActive,
        canSteer: canSteer,
        canResume: canResume,
        canRestart: task.canRestart,
        canDelete: session.tasks.allSatisfy { $0.isTerminal }
      )
    }

    static func taskDetail(
      _ task: MCPServiceTaskSnapshot,
      session: WorkbenchSessionItem?,
      projectName: String,
      conversation: TaskConversationModel?,
      permissionRemediation: BridgeDesktopPermissionRemediationState?,
      conversationEntries: [BridgeDesktopConversationEntry]? = nil,
      canResume: Bool,
      canSteer: Bool,
      pendingUserInput: Bool = false
    ) -> BridgeDesktopTaskDetail {
      let entries =
        conversationEntries
        ?? (conversation?.entries ?? []).map {
          conversationEntry($0, providerID: task.providerIdentifier)
        }
      let activity = task.recentActivity.map {
        BridgeDesktopActivityRow(
          id: "activity:\(task.taskID):\($0.sequence)",
          sequence: $0.sequence,
          kind: $0.kind,
          summary: $0.summary,
          occurredAt: $0.occurredAt
        )
      }
      let resolvedSession =
        session
        ?? WorkbenchSessionItem(
          sessionID: task.effectiveSessionID ?? task.taskID,
          providerID: task.providerIdentifier,
          providerDisplayName: task.providerDisplayName,
          providerSystemImage: task.providerSystemImage,
          projectID: task.projectID,
          tasks: [task]
        )
      return BridgeDesktopTaskDetail(
        taskID: task.taskID,
        sessionID: resolvedSession.sessionID,
        title: WorkbenchTaskTextPresentation.sessionMenuTitle(
          title: resolvedSession.title,
          turnCount: resolvedSession.turnCount
        ),
        projectName: projectName,
        status: desktopStatusLabel(task, pendingUserInput: pendingUserInput),
        isTerminal: task.isTerminal,
        provider: task.providerDisplayName,
        providerID: task.providerIdentifier,
        model: taskModelLabel(task),
        permissionMode: task.permissionMode,
        currentStep: task.currentStep,
        resultSummary: task.resultSummary,
        failureCode: task.failureCode,
        changedFiles: task.changedFiles,
        activity: activity,
        conversation: entries,
        conversationState: BridgeDesktopConversationState(
          conversation: conversation,
          activity: CodexActivityPresentation(
            task: task,
            activity: conversation?.activity ?? .idle,
            pendingUserInput: pendingUserInput
          )
        ),
        canInterrupt: TaskInspectorPresentation.canInterrupt(task),
        canStop: task.isActive,
        canSteer: canSteer,
        permissionRemediation: permissionRemediation,
        turnCount: resolvedSession.turnCount,
        canResume: canResume,
        canRestart: task.canRestart,
        updatedAt: task.updatedAt
      )
    }

    static func approvalItem(
      _ item: ApprovalPresentation.Item,
      approvals: [IPCApprovalSummary],
      directApprovals: [IPCPendingDirectApproval],
      tasks: [MCPServiceTaskSnapshot],
      projects: [MCPProjectSummary],
      resolvingApprovalIDs: Set<ApprovalPresentation.Identifier>,
      connected: Bool
    ) -> BridgeDesktopApprovalRow? {
      var approvalsByID: [String: IPCApprovalSummary] = [:]
      approvalsByID.reserveCapacity(approvals.count)
      for approval in approvals { approvalsByID[approval.approvalID] = approval }
      var directApprovalsByID: [String: IPCPendingDirectApproval] = [:]
      directApprovalsByID.reserveCapacity(directApprovals.count)
      for approval in directApprovals { directApprovalsByID[approval.approvalID] = approval }
      var tasksByID: [String: MCPServiceTaskSnapshot] = [:]
      tasksByID.reserveCapacity(tasks.count)
      for task in tasks { tasksByID[task.taskID] = task }
      var projectsByID: [String: MCPProjectSummary] = [:]
      projectsByID.reserveCapacity(projects.count)
      for project in projects { projectsByID[project.projectID] = project }
      return approvalItem(
        item,
        approvalsByID: approvalsByID,
        directApprovalsByID: directApprovalsByID,
        tasksByID: tasksByID,
        projectsByID: projectsByID,
        resolvingApprovalIDs: resolvingApprovalIDs,
        connected: connected
      )
    }

    static func approvalItem(
      _ item: ApprovalPresentation.Item,
      approvalsByID: [String: IPCApprovalSummary],
      directApprovalsByID: [String: IPCPendingDirectApproval],
      tasksByID: [String: MCPServiceTaskSnapshot],
      projectsByID: [String: MCPProjectSummary],
      resolvingApprovalIDs: Set<ApprovalPresentation.Identifier>,
      connected: Bool
    ) -> BridgeDesktopApprovalRow? {
      switch item.id {
      case .task(let approvalID):
        guard let approval = approvalsByID[approvalID] else { return nil }
        let projectID = tasksByID[approval.taskID]?.projectID
        let resolving = resolvingApprovalIDs.contains(.task(approvalID))
        return BridgeDesktopApprovalRow(
          approvalID: approvalID,
          taskID: approval.taskID,
          projectID: projectID,
          kind: approval.kind,
          title: approval.title,
          summary: approval.summary,
          displayCommand: approval.displayCommand,
          relativePaths: approval.relativePaths,
          reason: approval.reason,
          decisionOptions: item.allowDecisions,
          canAllow: connected && !resolving && !item.allowDecisions.isEmpty,
          canDeny: connected && !resolving,
          resolving: resolving,
          oneTimeToolAutoApprovalAvailable: approval.oneTimeToolAutoApprovalAvailable,
          questions: approval.questions?.map {
            BridgeDesktopApprovalQuestion(
              id: $0.id,
              header: $0.header,
              question: $0.question,
              isOther: $0.isOther,
              isSecret: $0.isSecret,
              options: $0.options.map {
                BridgeDesktopApprovalOption(label: $0.label, description: $0.description)
              }
            )
          } ?? []
        )
      case .direct(let approvalID):
        guard let approval = directApprovalsByID[approvalID] else { return nil }
        let resolving = resolvingApprovalIDs.contains(.direct(approvalID))
        return BridgeDesktopApprovalRow(
          approvalID: approvalID,
          projectID: approval.projectID,
          isDirect: true,
          kind: approval.kind,
          title: "Direct 审批",
          summary: approval.summary,
          reason: projectsByID[approval.projectID].map { "项目：\($0.name)" },
          decisionOptions: ["allow"],
          canAllow: connected && !resolving,
          canDeny: connected && !resolving,
          resolving: resolving
        )
      }
    }

    private static func conversationEntry(
      _ entry: TaskConversationModel.Entry,
      providerID: String
    ) -> BridgeDesktopConversationEntry {
      WindowsConversationEntryPresenter.make(entry, providerID: providerID)
    }

    private static func taskModelLabel(_ task: MCPServiceTaskSnapshot) -> String? {
      guard let model = task.executionModel?.trimmingCharacters(in: .whitespacesAndNewlines),
        !model.isEmpty
      else { return nil }
      guard let effort = task.executionEffort?.trimmingCharacters(in: .whitespacesAndNewlines),
        !effort.isEmpty
      else { return model }
      return "\(model) · \(BridgeDesktopPresentation.extendedReasoningTitle(effort))"
    }

    private static func desktopStatusLabel(
      _ task: MCPServiceTaskSnapshot,
      pendingUserInput: Bool = false
    ) -> String {
      if pendingUserInput { return "等待回答" }
      return WorkbenchTaskTextPresentation.statusLabel(task.status)
    }
  }
#endif
