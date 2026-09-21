#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore

  extension WindowsWorkbenchModel {
    static let permissionModes = ["read-only", "workspace-write"]

    var workbenchDisplaySnapshot: WindowsWorkbenchPresentationSnapshot {
      workbenchDisplayCache.snapshot(
        tasks: tasks,
        projects: projects,
        providers: agentProviders,
        installations: agentInstallations,
        approvals: approvals,
        directApprovals: directApprovals,
        selectedProjectID: selectedProjectID
      )
    }

    var visibleTasks: [MCPServiceTaskSnapshot] {
      workbenchDisplaySnapshot.visibleTasks
    }

    var visibleSessions: [WorkbenchSessionItem] {
      workbenchDisplaySnapshot.visibleSessions
    }

    var allSessions: [WorkbenchSessionItem] {
      workbenchDisplaySnapshot.allSessions
    }

    func publishDisplay() {
      let cached = workbenchDisplaySnapshot
      let task = selectedTaskID.flatMap { cached.taskByID[$0] }
      let selectedSession = task.flatMap { cached.sessionByTaskID[$0.taskID] }
      let selectedSessionIndex = selectedSession.flatMap { selected in
        cached.visibleSessions.firstIndex { $0.id == selected.id }
      }
      let workbenchRows = cached.visibleSessions.map(Self.sessionRowText)
      let selectedIndex = selectedSessionIndex
      var conversationEntries: [BridgeDesktopConversationEntry]?
      if let task {
        conversationEntries = windowsConversationPresentationCache.update(
          taskID: task.taskID,
          providerID: task.providerIdentifier,
          entries: conversation?.entries ?? []
        )
      } else {
        windowsConversationPresentationCache.reset()
      }
      let approvalItems = cached.approvalItems
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
      let taskItems = cached.visibleSessions.map { session in
        let latest = session.latestTask
        return Self.sessionItem(
          session,
          projectName: cached.projectName(for: latest.projectID),
          selectedTaskID: selectedTaskID,
          canSteer: TaskInspectorPresentation.canSteer(
            latest,
            providerSupportsSteer: cached.providerSupportsSteer(for: latest)
          ),
          canResume: TaskInspectorPresentation.canResume(
            latest,
            providerSupportsSessionContinuation: cached.providerSupportsSessionContinuation(
              for: latest
            )
          ),
          pendingUserInput: session.tasks.contains {
            cached.pendingUserInputTaskIDs.contains($0.taskID)
          }
        )
      }
      let selectedTaskDetail = task.map {
        Self.taskDetail(
          $0,
          session: selectedSession,
          projectName: cached.projectName(for: $0.projectID),
          conversation: conversation,
          permissionRemediation: desktopPermissionRemediation(for: $0),
          conversationEntries: conversationEntries,
          installations: agentInstallations,
          gitState: projects.first { $0.projectID == task?.projectID }?.gitState,
          canResume: TaskInspectorPresentation.canResume(
            $0,
            providerSupportsSessionContinuation: cached.providerSupportsSessionContinuation(
              for: $0
            )
          ),
          canSteer: TaskInspectorPresentation.canSteer(
            $0, providerSupportsSteer: cached.providerSupportsSteer(for: $0)
          ),
          pendingUserInput: cached.pendingUserInputTaskIDs.contains($0.taskID)
        )
      }
      let typedApprovals = approvalItems.enumerated().compactMap {
        Self.approvalItem(
          $0.element,
          approvalsByID: cached.approvalByID,
          directApprovalsByID: cached.directApprovalByID,
          tasksByID: cached.taskByID,
          projectsByID: cached.projectByID,
          resolvingApprovalIDs: resolvingApprovalIDs,
          connected: connectionState == .connected && !approvalRefreshInProgress
        )
      }
      let recentSessions = cached.allSessions.prefix(12)
      displayBox.store(
        WindowsWorkbenchDisplay(
          connectionState: connectionState,
          mcpAddress: serviceStatus?.localMCPURL ?? "—",
          mcpState: serviceStatus?.status.mcpState ?? "未知",
          taskCount: cached.taskCount,
          runningTaskCount: cached.runningTaskCount,
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
            Self.recentTaskPresentation($0, projectName: cached.projectName(for: $0.projectID))
          },
          selectedTaskID: selectedTaskID,
          selectedTaskIndex: selectedIndex,
          taskMetadata: metadata(
            for: task,
            projectName: task.map { cached.projectName(for: $0.projectID) }
          ),
          projectLoadError: projectLoadError,
          interruptEnabled: connectionState == .connected
            && TaskInspectorPresentation.canInterrupt(task),
          stopEnabled: connectionState == .connected && task?.isActive == true,
          deleteEnabled: connectionState == .connected
            && selectedSession?.tasks.allSatisfy({ $0.isTerminal }) == true,
          steerEnabled: connectionState == .connected
            && TaskInspectorPresentation.canSteer(
              task,
              providerSupportsSteer: task.map {
                cached.providerSupportsSteer(for: $0)
              } ?? false
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
          detailText: errorMessage ?? projectLoadError,
          taskItems: taskItems,
          selectedTaskDetail: selectedTaskDetail,
          history: BridgeDesktopThreadHistoryState(),
          approvalItems: typedApprovals,
          browserEnabled: isChatBrowserEnabled,
          supportsImmediateSteer: task?.installationID.flatMap { installationID in
            cached.installationByID[installationID]
          }?.effectiveCapabilities.contains("lifecycle.steer_interrupt_and_continue") == true,
          canLoadEarlierConversation: conversation?.canLoadEarlier == true,
          defaultModel: modelPreferences?.executionModel ?? models.first?.displayName
            ?? models.first?.modelID,
          availableModelCount: models.count,
          modelError: modelError,
          commandReceipt: workbenchCommandReceipt
        )
      )
    }

    func setChatBrowserEnabled(_ enabled: Bool) {
      isChatBrowserEnabled = enabled
      publishDisplay()
    }

    func providerSupportsSteer(for task: MCPServiceTaskSnapshot?) -> Bool {
      guard let task else { return false }
      return workbenchDisplaySnapshot.providerSupportsSteer(for: task)
    }

    func providerSupportsSessionContinuation(for task: MCPServiceTaskSnapshot?) -> Bool {
      guard let task else { return false }
      return workbenchDisplaySnapshot.providerSupportsSessionContinuation(for: task)
    }

    private func metadata(for task: MCPServiceTaskSnapshot?, projectName: String?) -> String {
      if let task {
        return TaskInspectorPresentation.metadata(
          for: task,
          projectName: projectName
        )
      }
      return "未选择任务或会话"
    }

    func requestConversationDisplayUpdate(for taskID: String) {
      guard conversation?.taskID == taskID else { return }
      let isTerminal = workbenchDisplaySnapshot.taskByID[taskID]?.isTerminal == true
      let conversationFinished = conversation?.isStreaming == false
      guard !isTerminal, !conversationFinished else {
        conversationDisplayTask?.cancel()
        conversationDisplayTask = nil
        publishDisplay()
        return
      }
      guard conversationDisplayTask == nil else { return }
      conversationDisplayTask = Task { [weak self] in
        await Task.yield()
        guard !Task.isCancelled else { return }
        guard let self, self.conversation?.taskID == taskID else { return }
        self.conversationDisplayTask = nil
        self.publishDisplay()
      }
    }

    private static func sessionRowText(_ session: WorkbenchSessionItem) -> String {
      let task = session.latestTask
      let state = WorkbenchTaskTextPresentation.statusLabel(task.status)
      let title = WorkbenchTaskTextPresentation.sessionMenuTitle(
        title: session.title,
        turnCount: session.turnCount
      )
      return "\(session.providerDisplayName) · \(title) — \(state)"
    }

    private static func recentTaskPresentation(
      _ session: WorkbenchSessionItem,
      projectName: String
    ) -> WindowsRecentTaskPresentation {
      let task = session.latestTask
      let status = WorkbenchTaskTextPresentation.statusLabel(task.status)
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

  }
#endif
