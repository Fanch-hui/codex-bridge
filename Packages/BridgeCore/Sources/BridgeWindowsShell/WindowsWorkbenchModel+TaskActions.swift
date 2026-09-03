#if os(Windows)
  import BridgeMCP
  import BridgeServiceAppCore

  extension WindowsWorkbenchModel {
    public func refreshSelectedTask() async {
      actionText = "正在刷新任务…"
      publishDisplay()
      await refreshTasks()
      guard connectionState == .connected else { return }
      actionText = "任务列表已刷新。"
      publishDisplay()
    }

    public func selectTask(at index: Int) {
      guard tasks.indices.contains(index) else { return }
      selectTask(tasks[index])
    }

    public func selectTask(id: String) {
      guard let task = task(id: id) else { return }
      selectTask(task)
    }

    private func selectTask(_ task: MCPServiceTaskSnapshot) {
      guard selectedTaskID != task.taskID else {
        publishDisplay()
        return
      }
      if selectedProjectID != task.projectID {
        selectedProjectID = task.projectID
        threads = []
        Task {
          try? await client.setWorkbenchProject(projectID: task.projectID)
          await loadThreads()
        }
      }
      selectedTaskID = task.taskID
      selectedThreadID = task.isCodexTask ? task.threadID : nil
      selectedThreadPage = nil
      actionText = nil
      openConversation(for: task)
      publishDisplay()
    }

    public func stopSelectedTask() async {
      guard let selectedTaskID else {
        reportFailure("当前没有可停止的任务。", taskID: nil)
        return
      }
      await stopTask(id: selectedTaskID)
    }

    public func stopTask(id taskID: String) async {
      guard connectionState == .connected else {
        reportFailure("后台 Service 未连接，无法停止任务。", taskID: taskID)
        return
      }
      guard let task = task(id: taskID), task.isActive else {
        reportFailure("当前任务不可停止。", taskID: taskID)
        return
      }
      let requestTaskID = task.taskID
      setActionTextIfSelected("正在停止任务…", taskID: requestTaskID)
      do {
        try await client.stopTask(taskID: requestTaskID)
        await refreshTasks()
        reportSuccess("停止请求已发送。", taskID: requestTaskID)
      } catch {
        let message = BridgeServiceErrorMessage.message(error)
        await loadTasks()
        reportFailure("停止失败：\(message)", taskID: requestTaskID)
      }
    }

    public func deleteSelectedTask() async {
      guard let selectedTaskID else {
        reportFailure("只能删除已结束的任务。", taskID: nil)
        return
      }
      await deleteTask(id: selectedTaskID)
    }

    public func deleteTask(id taskID: String) async {
      guard connectionState == .connected else {
        reportFailure("后台 Service 未连接，无法删除任务。", taskID: taskID)
        return
      }
      guard let task = task(id: taskID), task.isTerminal else {
        reportFailure("只能删除已结束的任务。", taskID: taskID)
        return
      }
      let requestTaskID = task.taskID
      setActionTextIfSelected("正在删除任务…", taskID: requestTaskID)
      do {
        try await client.deleteTask(taskID: requestTaskID)
        let wasSelected = selectedTaskID == requestTaskID
        if wasSelected { clearSelectedTask() }
        await refreshTasks()
        reportSuccess("任务已删除。", taskID: wasSelected ? nil : requestTaskID)
      } catch {
        let message = BridgeServiceErrorMessage.message(error)
        await loadTasks()
        reportFailure("删除失败：\(message)", taskID: requestTaskID)
      }
    }

    public func interruptSelectedTask() async {
      guard let selectedTaskID else {
        reportFailure("请先选择要中断的任务。", taskID: nil)
        return
      }
      await interruptTask(id: selectedTaskID)
    }

    public func interruptTask(id taskID: String) async {
      guard connectionState == .connected else {
        reportFailure("后台 Service 未连接，无法中断任务。", taskID: taskID)
        return
      }
      guard let task = task(id: taskID) else {
        reportFailure("任务不存在或已经移除。", taskID: taskID)
        return
      }
      guard let expectedTurnID = task.expectedControlID else {
        reportFailure("当前任务不可中断。", taskID: taskID)
        return
      }
      let requestTaskID = task.taskID
      setActionTextIfSelected("正在发送中断请求…", taskID: requestTaskID)
      do {
        _ = try await client.interruptTask(
          taskID: requestTaskID,
          expectedTurnID: expectedTurnID
        )
        await refreshTasks()
        reportSuccess("中断请求已发送。", taskID: requestTaskID)
      } catch {
        let message = BridgeServiceErrorMessage.message(error)
        await loadTasks()
        reportFailure("中断失败：\(message)", taskID: requestTaskID)
      }
    }

    public func submitSteer(
      input: String,
      mode: MCPTaskSteerMode = .queued
    ) async -> Bool {
      guard let selectedTaskID else {
        reportFailure("请先选择要发送 Steer 的任务。", taskID: nil)
        return false
      }
      return await submitSteer(taskID: selectedTaskID, input: input, mode: mode)
    }

    public func submitSteer(
      taskID: String,
      input: String,
      mode: MCPTaskSteerMode = .queued
    ) async -> Bool {
      guard connectionState == .connected else {
        reportFailure("后台 Service 未连接，无法发送 Steer。", taskID: taskID)
        return false
      }
      guard let task = task(id: taskID) else {
        reportFailure("任务不存在或已经移除。", taskID: taskID)
        return false
      }
      guard
        TaskInspectorPresentation.canSteer(
          task,
          providerSupportsSteer: providerSupportsSteer(for: task)
        )
      else {
        reportFailure("当前任务不支持 Steer。", taskID: taskID)
        return false
      }
      if mode == .interruptCurrentThenContinue {
        let supportsImmediate =
          task.installationID.flatMap { installationID in
            agentInstallations.first(where: { $0.installationID == installationID })
          }?.effectiveCapabilities.contains("lifecycle.steer_interrupt_and_continue") == true
        guard supportsImmediate else {
          reportFailure("当前 Agent 不支持立即 Steer。", taskID: taskID)
          return false
        }
      }
      guard let validationMessage = TaskInspectorPresentation.steerValidationMessage(input)
      else {
        setActionTextIfSelected("正在发送 Steer…", taskID: taskID)
        do {
          guard let expectedTurnID = task.expectedControlID else {
            reportFailure("当前任务已不在可 Steer 状态。", taskID: taskID)
            return false
          }
          let requestTaskID = task.taskID
          _ = try await client.steerTask(
            taskID: requestTaskID,
            expectedTurnID: expectedTurnID,
            input: input,
            mode: mode
          )
          await refreshTasks()
          reportSuccess("Steer 已发送。", taskID: requestTaskID)
          return true
        } catch {
          let message = BridgeServiceErrorMessage.message(error)
          await loadTasks()
          reportFailure("Steer 发送失败：\(message)", taskID: task.taskID)
          return false
        }
      }
      reportFailure(validationMessage, taskID: taskID)
      return false
    }

    private func setActionText(_ text: String) {
      actionText = text
      publishDisplay()
    }

    private func setActionTextIfSelected(_ text: String, taskID: String) {
      guard selectedTaskID == taskID else { return }
      setActionText(text)
    }

    private func reportSuccess(_ text: String, taskID: String?) {
      if let taskID { setActionTextIfSelected(text, taskID: taskID) }
      feedback.postToast(text)
    }

    private func reportFailure(_ text: String, taskID: String?) {
      if let taskID {
        setActionTextIfSelected(text, taskID: taskID)
      } else {
        setActionText(text)
      }
      feedback.postAlert(text, title: "任务操作失败")
    }

    private func task(id: String) -> MCPServiceTaskSnapshot? {
      tasks.first(where: { $0.taskID == id })
    }

    private func clearSelectedTask() {
      selectedTaskID = nil
      selectedThreadID = nil
      selectedThreadPage = nil
      conversation?.cancel()
      conversation = nil
      conversationWasTerminal = false
      actionText = nil
    }
  }
#endif
