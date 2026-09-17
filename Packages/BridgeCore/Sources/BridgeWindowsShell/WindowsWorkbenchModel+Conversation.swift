#if os(Windows)
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore

  extension WindowsWorkbenchModel {
    func loadTasks() async {
      guard !taskLoadInProgress else { return }
      taskLoadInProgress = true
      defer { taskLoadInProgress = false }
      do {
        let nextTasks = try await client.tasks(IPCTaskListRequest())
        guard !Task.isCancelled, !isShuttingDown else { return }
        let tasksChanged = tasks != nextTasks
        let stateChanged = connectionState != .connected || errorMessage != nil
        if tasksChanged {
          tasks = nextTasks
        }
        errorMessage = nil
        connectionState = .connected
        let previousSelection = selectedTaskID
        reconcileSelectedTask()
        selectDefaultTaskIfNeeded()
        if tasksChanged || stateChanged || previousSelection != selectedTaskID {
          publishDisplay()
        }
      } catch {
        guard !Task.isCancelled, !isShuttingDown else { return }
        fail(BridgeServiceErrorMessage.message(error))
      }
    }

    func reconcileSelectedTask() {
      guard let selectedTaskID else { return }
      guard
        let task = workbenchDisplaySnapshot.taskByID[selectedTaskID],
        selectedProjectID == nil || task.projectID == selectedProjectID
      else {
        self.selectedTaskID = nil
        closeConversation()
        conversationWasTerminal = false
        actionText = nil
        return
      }
      if conversation?.taskID != task.taskID || conversationWasTerminal != task.isTerminal {
        openConversation(for: task)
      }
      conversationWasTerminal = task.isTerminal
    }

    func openConversation(for task: MCPServiceTaskSnapshot) {
      closeConversation()
      let sessionTasks =
        workbenchDisplaySnapshot.sessionByTaskID[task.taskID]?.tasks ?? [task]
      let priorTaskIDs =
        sessionTasks
        .filter { $0.taskID != task.taskID && $0.updatedAt <= task.updatedAt }
        .map(\.taskID)
      let next = TaskConversationModel(
        taskID: task.taskID,
        priorTaskIDs: priorTaskIDs,
        client: client,
        isTerminal: task.isTerminal,
        updateHandler: { [weak self] in
          guard let self, self.conversation?.taskID == task.taskID else { return }
          self.requestConversationDisplayUpdate(for: task.taskID)
        }
      )
      next.restorePresentation(
        conversationPresentationCache.snapshot(for: task.taskID, priorTaskIDs: priorTaskIDs)
      )
      conversation = next
      conversationWasTerminal = task.isTerminal
      Task { [weak self, weak next] in
        await next?.start()
        guard let self, self.conversation === next else { return }
        self.publishDisplay()
      }
    }

    func closeConversation() {
      guard let current = conversation else { return }
      conversationDisplayTask?.cancel()
      conversationDisplayTask = nil
      conversationPresentationCache.store(
        current.presentationSnapshot(),
        for: current.taskID
      )
      windowsConversationPresentationCache.reset()
      current.cancel()
      conversation = nil
    }

    var selectedTask: MCPServiceTaskSnapshot? {
      guard let selectedTaskID else { return nil }
      return workbenchDisplaySnapshot.taskByID[selectedTaskID]
    }
  }
#endif
