#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore

  extension WindowsWorkbenchModel {
    static let permissionModes = ["read-only", "workspace-write"]

    var visibleTasks: [MCPServiceTaskSnapshot] {
      tasks.filter { selectedProjectID == nil || $0.projectID == selectedProjectID }
    }

    var visibleSessions: [WorkbenchSessionItem] {
      WorkbenchSessionCatalog.sessions(tasks: visibleTasks)
        .sorted { $0.latestTask.updatedAt > $1.latestTask.updatedAt }
    }

    var allSessions: [WorkbenchSessionItem] {
      WorkbenchSessionCatalog.sessions(tasks: tasks)
        .sorted { $0.latestTask.updatedAt > $1.latestTask.updatedAt }
    }

    var orphanThreads: [MCPThreadSummary] {
      WorkbenchSessionCatalog.orphanThreads(tasks: visibleTasks, threads: threads)
    }

    func publishDisplay() {
      let runningCount = tasks.filter { $0.isRunning }.count
      let task = selectedTask
      let selectedSession = task.flatMap { selectedTask in
        visibleSessions.first { session in
          session.tasks.contains(where: { $0.taskID == selectedTask.taskID })
        }
      }
      let selectedSessionIndex = selectedSession.flatMap { selected in
        visibleSessions.firstIndex(where: {
          $0.id == selected.id && $0.providerID == selected.providerID
        })
      }
      let selectedThreadIndex = selectedThreadID.flatMap { selectedID in
        orphanThreads.firstIndex(where: { $0.threadID == selectedID })
      }
      let workbenchRows =
        visibleSessions.map(Self.sessionRowText) + orphanThreads.map(Self.threadRowText)
      let selectedIndex =
        selectedSessionIndex ?? selectedThreadIndex.map { visibleSessions.count + $0 }
      let conversationText =
        selectedThreadPage.map(Self.threadConversationText)
        ?? TaskInspectorPresentation.conversationText(
          entries: conversation?.entries ?? [],
          isStreaming: conversation?.isStreaming == true || task?.isRunning == true,
          errorMessage: conversation?.errorMessage
        )
      let approvalItems = approvalPresentationItems()
      let selectedApprovalIndex = selectedApprovalID.flatMap { selectedID in
        approvalItems.firstIndex(where: { $0.id == selectedID })
      }
      let selectedApproval = selectedApprovalIndex.flatMap { approvalItems[$0] }
      let approvalResolving = selectedApprovalID.map(resolvingApprovalIDs.contains) ?? false
      let approvalActionsEnabled =
        connectionState == .connected
        && selectedApproval != nil
        && !approvalResolving
        && !approvalRefreshInProgress
      let taskItems = visibleSessions.map { session in
        let latest = session.latestTask
        return Self.sessionItem(
          session,
          projectName: projectName(for: latest.projectID),
          selectedTaskID: selectedTaskID,
          canSteer: TaskInspectorPresentation.canSteer(
            latest,
            providerSupportsSteer: providerSupportsSteer(for: latest)
          ),
          canResume: TaskInspectorPresentation.canResume(
            latest,
            providerSupportsSessionContinuation: providerSupportsSessionContinuation(for: latest)
          )
        )
      }
      let selectedTaskDetail = task.map {
        Self.taskDetail(
          $0,
          session: selectedSession,
          projectName: projectName(for: $0.projectID),
          conversation: conversation,
          selectedThreadPage: selectedThreadPage,
          permissionRemediation: desktopPermissionRemediation(for: $0),
          canResume: TaskInspectorPresentation.canResume(
            $0,
            providerSupportsSessionContinuation: providerSupportsSessionContinuation(for: $0)
          ),
          canSteer: TaskInspectorPresentation.canSteer(
            $0, providerSupportsSteer: providerSupportsSteer(for: $0)
          )
        )
      }
      let typedApprovals = approvalPresentationItems().enumerated().compactMap {
        Self.approvalItem(
          $0.element,
          approvals: approvals,
          directApprovals: directApprovals,
          tasks: tasks,
          projects: projects,
          resolvingApprovalIDs: resolvingApprovalIDs,
          connected: connectionState == .connected && !approvalRefreshInProgress
        )
      }
      let recentSessions = allSessions.prefix(12)
      displayBox.store(
        WindowsWorkbenchDisplay(
          connectionState: connectionState,
          mcpAddress: serviceStatus?.localMCPURL ?? "—",
          mcpState: serviceStatus?.status.mcpState ?? "未知",
          taskCount: tasks.count,
          runningTaskCount: runningCount,
          pendingApprovalCount: approvalItems.count,
          projectRows: projects.map(\.name),
          selectedProjectIndex: selectedProjectID.flatMap { selectedID in
            projects.firstIndex(where: { $0.projectID == selectedID })
          },
          selectedProjectID: selectedProjectID,
          permissionRows: ["只读", "可写"],
          selectedPermissionIndex: Self.permissionModes.firstIndex(of: workbenchPermissionMode),
          permissionMode: workbenchPermissionMode,
          taskRows: workbenchRows,
          recentTaskRows: recentSessions.map(Self.sessionRowText),
          recentTasks: recentSessions.map {
            Self.recentTaskPresentation($0, projectName: projectName(for: $0.projectID))
          },
          selectedTaskID: selectedTaskID,
          selectedTaskIndex: selectedIndex,
          taskMetadata: metadata(for: task),
          conversationText: conversationText,
          interruptEnabled: connectionState == .connected
            && TaskInspectorPresentation.canInterrupt(task),
          stopEnabled: connectionState == .connected && task?.isActive == true,
          deleteEnabled: connectionState == .connected
            && selectedSession?.tasks.allSatisfy({ $0.isTerminal }) == true,
          steerEnabled: connectionState == .connected
            && TaskInspectorPresentation.canSteer(
              task,
              providerSupportsSteer: providerSupportsSteer(for: task)
            ),
          actionText: actionText,
          approvalRows: approvalItems.map(\.rowText),
          selectedApprovalIndex: selectedApprovalIndex,
          approvalDetailText: selectedApproval?.detailText ?? "暂无待处理审批。",
          approvalAllowDecisions: selectedApproval?.allowDecisions ?? [],
          approvalAllowEnabled: approvalActionsEnabled
            && !(selectedApproval?.allowDecisions.isEmpty ?? true),
          approvalDenyEnabled: approvalActionsEnabled,
          approvalStatusText: approvalStatusText,
          detailText: errorMessage,
          taskItems: taskItems,
          selectedTaskDetail: selectedTaskDetail,
          history: threadHistory(),
          approvalItems: typedApprovals,
          browserEnabled: isChatBrowserEnabled,
          supportsImmediateSteer: task?.installationID.flatMap { installationID in
            agentInstallations.first(where: { $0.installationID == installationID })
          }?.effectiveCapabilities.contains("lifecycle.steer_interrupt_and_continue") == true,
          canLoadEarlierConversation: conversation?.canLoadEarlier == true,
          defaultModel: modelPreferences?.executionModel ?? models.first?.displayName
            ?? models.first?.modelID,
          availableModelCount: models.count,
          modelError: modelError
        )
      )
    }

    func setChatBrowserEnabled(_ enabled: Bool) {
      isChatBrowserEnabled = enabled
      publishDisplay()
    }

    func providerSupportsSteer(for task: MCPServiceTaskSnapshot?) -> Bool {
      guard let task else { return false }
      if task.isCodexTask { return true }
      let providerID = task.providerIdentifier
      return agentProviders.contains {
        AgentProviderPresentation.identifier($0.providerID) == providerID && $0.supportsSteer
      }
    }

    func providerSupportsSessionContinuation(for task: MCPServiceTaskSnapshot?) -> Bool {
      guard let task else { return false }
      if task.isCodexTask { return true }
      let providerID = task.providerIdentifier
      return agentProviders.contains {
        AgentProviderPresentation.identifier($0.providerID) == providerID
          && $0.supportsSessionContinuation
      }
    }

    private func metadata(for task: MCPServiceTaskSnapshot?) -> String {
      if let task {
        return TaskInspectorPresentation.metadata(
          for: task,
          projectName: projectName(for: task.projectID)
        )
      }
      if let thread = selectedThreadPage?.thread {
        return
          "Codex 历史会话\r\n\(thread.title ?? thread.preview ?? thread.threadID)\r\n状态：\(thread.status)"
      }
      return "未选择任务或会话"
    }

    private func projectName(for projectID: String) -> String {
      projects.first(where: { $0.projectID == projectID })?.name ?? projectID
    }

    private static func sessionRowText(_ session: WorkbenchSessionItem) -> String {
      let task = session.latestTask
      let state = task.isRunning ? "运行中" : (task.isTerminal ? "已结束" : task.status)
      let title = WorkbenchTaskTextPresentation.sessionMenuTitle(
        title: session.title,
        turnCount: session.turnCount
      )
      return "\(session.providerDisplayName) · \(title) — \(state)"
    }

    private static func threadRowText(_ thread: MCPThreadSummary) -> String {
      "Codex · \(thread.title ?? thread.preview ?? thread.threadID) — \(thread.status)"
    }

    private static func recentTaskPresentation(
      _ session: WorkbenchSessionItem,
      projectName: String
    ) -> WindowsRecentTaskPresentation {
      let task = session.latestTask
      let status = task.isRunning ? "运行中" : (task.isTerminal ? "已结束" : task.status)
      return WindowsRecentTaskPresentation(
        taskID: task.taskID,
        title: WorkbenchTaskTextPresentation.sessionMenuTitle(
          title: session.title,
          turnCount: session.turnCount
        ),
        projectName: projectName,
        source: task.sourceDisplayName,
        status: status,
        updatedAt: task.updatedAt
      )
    }

    private static func threadConversationText(_ page: MCPThreadReadPage) -> String {
      guard !page.entries.isEmpty else { return "此 Codex 会话暂无可显示记录。" }
      return page.entries.map { entry in
        let role = entry.role == "user" ? "用户" : (entry.role == "assistant" ? "Codex" : entry.role)
        return "\(role)：\(entry.text)"
      }.joined(separator: "\r\n\r\n")
    }
  }
#endif
