#if os(Windows) || os(Linux)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeServiceAppCore

  extension WindowsWorkbenchModel {
    func submitDSHTask(_ envelope: BridgeDesktopCommandEnvelope) async -> Bool {
      let payload = envelope.payload
      guard connectionState == .connected else {
        rejectDSHTask(envelope, message: "后台 Service 未连接，无法提交任务。", canEditInput: true)
        return false
      }
      let request: IPCAgentSubmitRequest
      do {
        request = try DSHWorkbenchTaskSubmission.request(
          projectID: payload.projectID,
          installationID: payload.installationID,
          prompt: payload.input,
          model: payload.modelID,
          effort: payload.effort,
          skillNames: payload.skillNames,
          attachmentPaths: payload.attachmentPaths,
          permissionMode: payload.permissionMode ?? "full",
          clientRequestID: envelope.requestID,
          queueIfBusy: payload.queueIfBusy ?? false,
          registeredProjectIDs: Set(projects.map(\.projectID)),
          installations: agentInstallations
        )
      } catch {
        rejectDSHTask(
          envelope, message: BridgeServiceErrorMessage.message(error), canEditInput: true)
        return false
      }
      let response: IPCAgentSubmitResponse
      do {
        response = try await client.submitAgentTask(request)
      } catch {
        rejectDSHTask(
          envelope, message: BridgeServiceErrorMessage.message(error),
          canEditInput: DSHWorkbenchTaskSubmission.canEditInput(after: error))
        return false
      }
      await refreshTasks()
      if task(id: response.taskID) == nil {
        do {
          let submittedTask = try await client.task(IPCTaskRequest(taskID: response.taskID))
          if task(id: response.taskID) == nil { tasks.append(submittedTask) }
        } catch {
          feedback.postAlert("任务已提交，读取会话失败：\(BridgeServiceErrorMessage.message(error))")
        }
      }
      selectTask(id: response.taskID)
      recordWorkbenchCommandReceipt(
        requestID: envelope.requestID,
        command: envelope.command.rawValue,
        taskID: nil,
        input: payload.input,
        accepted: true,
        resultingTaskID: response.taskID
      )
      return selectedTaskID == response.taskID
    }

    private func rejectDSHTask(
      _ envelope: BridgeDesktopCommandEnvelope, message: String, canEditInput: Bool? = nil
    ) {
      rejectWorkbenchCommand(
        requestID: envelope.requestID,
        command: envelope.command.rawValue,
        taskID: nil,
        input: envelope.payload.input,
        message: message,
        canEditInput: canEditInput
      )
    }
  }
#endif
