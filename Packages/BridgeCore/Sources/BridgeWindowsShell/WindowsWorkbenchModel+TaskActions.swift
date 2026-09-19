#if os(Windows)
  import BridgeIPC
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
      guard visibleSessions.indices.contains(index) else { return }
      selectTask(visibleSessions[index].latestTask)
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
      mode: MCPTaskSteerMode = .queued,
      requestID: String? = nil
    ) async -> Bool {
      guard let selectedTaskID else {
        rejectWorkbenchCommand(
          requestID: requestID,
          command: "steerTask",
          taskID: nil,
          input: input,
          message: "请先选择要发送 Steer 的任务。"
        )
        reportFailure("请先选择要发送 Steer 的任务。", taskID: nil)
        return false
      }
      return await submitSteer(
        taskID: selectedTaskID, input: input, mode: mode, requestID: requestID
      )
    }

    public func submitSteer(
      taskID: String,
      input: String,
      mode: MCPTaskSteerMode = .queued,
      requestID: String? = nil
    ) async -> Bool {
      guard connectionState == .connected else {
        rejectWorkbenchCommand(
          requestID: requestID, command: "steerTask", taskID: taskID, input: input,
          message: "后台 Service 未连接，无法发送 Steer。"
        )
        reportFailure("后台 Service 未连接，无法发送 Steer。", taskID: taskID)
        return false
      }
      guard let task = task(id: taskID) else {
        rejectWorkbenchCommand(
          requestID: requestID, command: "steerTask", taskID: taskID, input: input,
          message: "任务不存在或已经移除。"
        )
        reportFailure("任务不存在或已经移除。", taskID: taskID)
        return false
      }
      guard
        TaskInspectorPresentation.canSteer(
          task,
          providerSupportsSteer: providerSupportsSteer(for: task)
        )
      else {
        rejectWorkbenchCommand(
          requestID: requestID, command: "steerTask", taskID: taskID, input: input,
          message: "当前任务不支持 Steer。"
        )
        reportFailure("当前任务不支持 Steer。", taskID: taskID)
        return false
      }
      if mode == .interruptCurrentThenContinue {
        let supportsImmediate =
          task.installationID.flatMap { installationID in
            workbenchDisplaySnapshot.installationByID[installationID]
          }?.effectiveCapabilities.contains("lifecycle.steer_interrupt_and_continue") == true
        guard supportsImmediate else {
          rejectWorkbenchCommand(
            requestID: requestID, command: "steerTask", taskID: taskID, input: input,
            message: "当前 Agent 不支持立即 Steer。"
          )
          reportFailure("当前 Agent 不支持立即 Steer。", taskID: taskID)
          return false
        }
      }
      guard let validationMessage = TaskInspectorPresentation.steerValidationMessage(input)
      else {
        setActionTextIfSelected("正在发送 Steer…", taskID: taskID)
        do {
          guard let expectedTurnID = task.expectedControlID else {
            rejectWorkbenchCommand(
              requestID: requestID, command: "steerTask", taskID: taskID, input: input,
              message: "当前任务已不在可 Steer 状态。"
            )
            reportFailure("当前任务已不在可 Steer 状态。", taskID: taskID)
            return false
          }
          let requestTaskID = task.taskID
          let receipt = try await client.steerTask(
            taskID: requestTaskID,
            expectedTurnID: expectedTurnID,
            input: input,
            mode: mode
          )
          await refreshTasks()
          let message = receipt.accepted ? nil : "本机 Service 未接受这次 Steer。"
          recordWorkbenchCommandReceipt(
            requestID: requestID,
            command: "steerTask",
            taskID: requestTaskID,
            input: input,
            accepted: receipt.accepted,
            message: message
          )
          if receipt.accepted {
            reportSuccess("Steer 已发送。", taskID: requestTaskID)
          } else {
            reportFailure(message ?? "本机 Service 未接受这次 Steer。", taskID: requestTaskID)
          }
          return receipt.accepted
        } catch {
          let message = BridgeServiceErrorMessage.message(error)
          await loadTasks()
          recordWorkbenchCommandReceipt(
            requestID: requestID,
            command: "steerTask",
            taskID: task.taskID,
            input: input,
            accepted: false,
            message: message
          )
          reportFailure("Steer 发送失败：\(message)", taskID: task.taskID)
          return false
        }
      }
      rejectWorkbenchCommand(
        requestID: requestID,
        command: "steerTask",
        taskID: taskID,
        input: input,
        message: validationMessage
      )
      reportFailure(validationMessage, taskID: taskID)
      return false
    }

    public func resumeTask(id taskID: String, input: String?, requestID: String? = nil) async {
      guard connectionState == .connected, let task = task(id: taskID),
        TaskInspectorPresentation.canResume(
          task,
          providerSupportsSessionContinuation: providerSupportsSessionContinuation(for: task)
        ),
        let sessionID = task.effectiveSessionID
      else {
        rejectWorkbenchCommand(
          requestID: requestID, command: "resumeTask", taskID: taskID, input: input,
          message: "当前任务无法续接会话。"
        )
        reportFailure("当前任务无法续接会话。", taskID: taskID)
        return
      }
      let trimmed = input?.trimmingCharacters(in: .whitespacesAndNewlines)
      await submitRetry(
        task: task,
        prompt: trimmed.flatMap { $0.isEmpty ? nil : $0 } ?? "继续执行未完成的任务",
        threadID: sessionID,
        progress: "正在续接任务…",
        success: "已续接任务。",
        requestID: requestID,
        command: "resumeTask",
        receiptInput: input ?? ""
      )
    }

    public func restartTask(id taskID: String, requestID: String? = nil) async {
      guard connectionState == .connected, let task = task(id: taskID), task.canRestart,
        let prompt = task.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
        !prompt.isEmpty
      else {
        rejectWorkbenchCommand(
          requestID: requestID, command: "restartTask", taskID: taskID, input: nil,
          message: "当前任务没有可用于重新开始的原始指令。"
        )
        reportFailure("当前任务没有可用于重新开始的原始指令。", taskID: taskID)
        return
      }
      await submitRetry(
        task: task,
        prompt: prompt,
        threadID: nil,
        progress: "正在重新开始任务…",
        success: "已重新开始任务。",
        requestID: requestID,
        command: "restartTask",
        receiptInput: nil
      )
    }

    public func deleteSession(containingTaskID taskID: String) async {
      guard connectionState == .connected, let task = task(id: taskID) else {
        reportFailure("会话不存在或已经移除。", taskID: taskID)
        return
      }
      let relatedTasks = workbenchDisplaySnapshot.sessionByTaskID[task.taskID]?.tasks ?? [task]
      guard !relatedTasks.isEmpty, relatedTasks.allSatisfy({ $0.isTerminal }) else {
        reportFailure("运行中的会话不能删除。", taskID: taskID)
        return
      }
      let relatedIDs = Set(relatedTasks.map(\.taskID))
      setActionTextIfSelected("正在删除会话…", taskID: taskID)
      do {
        for relatedTask in relatedTasks {
          try await client.deleteTask(taskID: relatedTask.taskID)
        }
        if let selectedTaskID, relatedIDs.contains(selectedTaskID) {
          clearSelectedTask()
        }
        await refreshTasks()
        reportSuccess("会话已删除。", taskID: nil)
      } catch {
        await loadTasks()
        reportFailure(
          "删除会话失败：\(BridgeServiceErrorMessage.message(error))",
          taskID: relatedIDs.contains(selectedTaskID ?? "") ? nil : taskID
        )
      }
    }

    private func submitRetry(
      task: MCPServiceTaskSnapshot,
      prompt: String,
      threadID: String?,
      progress: String,
      success: String,
      requestID: String?,
      command: String,
      receiptInput: String?
    ) async {
      let request = IPCAgentSubmitRequest(
        projectID: task.projectID,
        providerID: task.providerIdentifier,
        installationID: task.installationID,
        model: task.executionModel,
        effort: task.executionEffort,
        permissionMode: task.permissionMode,
        prompt: prompt,
        threadID: threadID,
        networkAccess: task.networkAccess,
        modelOverride: TaskRetrySubmission.modelOverride(for: task),
        permissionModeOverride: task.permissionMode != nil
      )
      setActionTextIfSelected(progress, taskID: task.taskID)
      do {
        let response = try await client.submitAgentTask(request)
        await refreshTasks()
        selectTask(id: response.taskID)
        recordWorkbenchCommandReceipt(
          requestID: requestID,
          command: command,
          taskID: task.taskID,
          input: receiptInput,
          accepted: true
        )
        reportSuccess(success, taskID: response.taskID)
      } catch {
        await loadTasks()
        let message = BridgeServiceErrorMessage.message(error)
        recordWorkbenchCommandReceipt(
          requestID: requestID,
          command: command,
          taskID: task.taskID,
          input: receiptInput,
          accepted: false,
          message: message
        )
        reportFailure(
          "任务提交失败：\(message)",
          taskID: task.taskID
        )
      }
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
      workbenchDisplaySnapshot.taskByID[id]
    }

    private func clearSelectedTask() {
      selectedTaskID = nil
      selectedThreadID = nil
      selectedThreadPage = nil
      closeConversation()
      conversationWasTerminal = false
      actionText = nil
    }
  }
#endif
