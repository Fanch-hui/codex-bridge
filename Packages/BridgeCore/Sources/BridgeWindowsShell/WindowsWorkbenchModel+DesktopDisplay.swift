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
      canResume: Bool
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
        status: desktopStatusLabel(task),
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
      canResume: Bool,
      canSteer: Bool
    ) -> BridgeDesktopTaskDetail {
      let entries = (conversation?.entries ?? []).map {
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
        status: desktopStatusLabel(task),
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
          activity: CodexActivityPresentation(task: task, activity: conversation?.activity ?? .idle)
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
      switch item.id {
      case .task(let approvalID):
        guard let approval = approvals.first(where: { $0.approvalID == approvalID }) else {
          return nil
        }
        let projectID = tasks.first(where: { $0.taskID == approval.taskID })?.projectID
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
          oneTimeToolAutoApprovalAvailable: approval.oneTimeToolAutoApprovalAvailable
        )
      case .direct(let approvalID):
        guard let approval = directApprovals.first(where: { $0.approvalID == approvalID }) else {
          return nil
        }
        let resolving = resolvingApprovalIDs.contains(.direct(approvalID))
        return BridgeDesktopApprovalRow(
          approvalID: approvalID,
          projectID: approval.projectID,
          isDirect: true,
          kind: approval.kind,
          title: "Direct 审批",
          summary: approval.summary,
          reason: projects.first(where: { $0.projectID == approval.projectID }).map {
            "项目：\($0.name)"
          },
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

    private static func taskModelLabel(_ task: MCPServiceTaskSnapshot) -> String? {
      guard let model = task.executionModel?.trimmingCharacters(in: .whitespacesAndNewlines),
        !model.isEmpty
      else { return nil }
      guard let effort = task.executionEffort?.trimmingCharacters(in: .whitespacesAndNewlines),
        !effort.isEmpty
      else { return model }
      return "\(model) · \(BridgeDesktopPresentation.extendedReasoningTitle(effort))"
    }

    private static func desktopStatusLabel(_ task: MCPServiceTaskSnapshot) -> String {
      switch task.status {
      case "awaiting_local_approval": return "等待本机批准"
      case "starting": return "正在启动"
      case "running": return "运行中"
      case "waiting_for_codex_approval": return "等待 Codex 审批"
      case "completed": return "已完成"
      case "failed": return "失败"
      case "interrupted": return "已中断"
      default:
        if task.isRunning { return "运行中" }
        if task.isTerminal { return "已结束" }
        return task.status
      }
    }
  }
#endif
