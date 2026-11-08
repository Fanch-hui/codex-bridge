#if os(Windows) || os(Linux)
  import BridgeDesktopUI
  import BridgeMCP
  import BridgeServiceAppCore

  extension WindowsWorkbenchModel {
    /// Split-view panes, built like the selected task from each pane's own conversation.
    func paneTaskDetails(
      _ cached: WindowsWorkbenchPresentationSnapshot
    ) -> [BridgeDesktopTaskDetail]? {
      let ids = paneConversations.paneTaskIDs
      guard !ids.isEmpty else { return nil }
      return ids.compactMap { taskID in
        guard let task = cached.taskByID[taskID] else { return nil }
        return Self.taskDetail(
          task,
          session: cached.sessionByTaskID[taskID],
          projectName: cached.projectName(for: task.projectID),
          conversation: paneConversations.conversation(for: taskID),
          permissionRemediation: desktopPermissionRemediation(for: task),
          installations: agentInstallations,
          gitState: projects.first { $0.projectID == task.projectID }?.gitState,
          canResume: TaskInspectorPresentation.canResume(
            task,
            providerSupportsSessionContinuation: cached.providerSupportsSessionContinuation(
              for: task)
          ),
          canSteer: TaskInspectorPresentation.canSteer(
            task, providerSupportsSteer: cached.providerSupportsSteer(for: task)),
          pendingUserInput: cached.pendingUserInputTaskIDs.contains(taskID)
        )
      }
    }

    func setWorkbenchPanes(_ taskIDs: [String]) {
      if paneConversations.setPanes(taskIDs, tasks: tasks, client: client) { publishDisplay() }
    }
  }
#endif
