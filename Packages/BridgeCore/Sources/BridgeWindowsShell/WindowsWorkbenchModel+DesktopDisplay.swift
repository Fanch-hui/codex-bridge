#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore

  extension WindowsWorkbenchModel {
    static func taskItem(
      _ task: MCPServiceTaskSnapshot,
      projectName: String,
      selectedTaskID: String?,
      canSteer: Bool
    ) -> BridgeDesktopTaskRow {
      BridgeDesktopTaskRow(
        taskID: task.taskID,
        title: task.workbenchTitle,
        projectID: task.projectID,
        projectName: projectName,
        source: task.sourceDisplayName,
        provider: task.providerDisplayName,
        status: desktopStatusLabel(task),
        updatedAt: task.updatedAt,
        selected: task.taskID == selectedTaskID,
        isRunning: task.isRunning,
        isActive: task.isActive,
        canInterrupt: TaskInspectorPresentation.canInterrupt(task),
        canStop: task.isActive,
        canSteer: canSteer,
        canDelete: task.isTerminal
      )
    }

    static func taskDetail(
      _ task: MCPServiceTaskSnapshot,
      projectName: String,
      conversation: TaskConversationModel?,
      selectedThreadPage: MCPThreadReadPage?,
      permissionRemediation: BridgeDesktopPermissionRemediationState?
    ) -> BridgeDesktopTaskDetail {
      let entries: [BridgeDesktopConversationEntry]
      if let selectedThreadPage {
        entries = selectedThreadPage.entries.enumerated().map { index, entry in
          BridgeDesktopConversationEntry(
            id: "history:\(selectedThreadPage.thread.threadID):\(index)",
            role: entry.role,
            text: entry.text
          )
        }
      } else {
        entries = (conversation?.entries ?? []).map {
          BridgeDesktopConversationEntry(
            id: $0.key,
            role: $0.role == "user" ? "用户" : "Agent",
            text: $0.content,
            kind: $0.kind,
            toolName: $0.toolName,
            toolStatus: $0.toolStatus,
            toolArguments: $0.toolArguments,
            isFinal: $0.isFinal,
            status: $0.isFinal ? "final" : "streaming"
          )
        }
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
      return BridgeDesktopTaskDetail(
        taskID: task.taskID,
        title: task.workbenchTitle,
        projectName: projectName,
        status: desktopStatusLabel(task),
        provider: task.providerDisplayName,
        model: task.executionModel,
        permissionMode: task.permissionMode,
        currentStep: task.currentStep,
        resultSummary: task.resultSummary,
        failureCode: task.failureCode,
        changedFiles: task.changedFiles,
        activity: activity,
        conversation: entries,
        permissionRemediation: permissionRemediation,
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
