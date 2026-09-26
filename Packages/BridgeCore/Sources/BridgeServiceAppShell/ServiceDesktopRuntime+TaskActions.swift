import BridgeDesktopUI
import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore
import Foundation

extension BridgeServiceAppModel {
  public func stopTask(_ taskID: String) {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.stopTask(taskID: taskID)
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func interruptTask(_ task: MCPServiceTaskSnapshot) {
    guard let expectedTurnID = task.expectedControlID else { return }
    runMutation { [weak self] client in
      guard let self else { return }
      _ = try await client.interruptTask(
        taskID: task.taskID,
        expectedTurnID: expectedTurnID
      )
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func steerTask(
    _ task: MCPServiceTaskSnapshot,
    input: String,
    mode: MCPTaskSteerMode = .queued,
    requestID: String? = nil
  ) {
    guard let expectedTurnID = task.expectedControlID,
      !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      input.utf8.count <= IPCTaskSteerRequest.maximumInputBytes,
      !input.contains("\0")
    else {
      rejectWorkbenchCommand(
        requestID: requestID,
        command: BridgeDesktopCommand.steerTask.rawValue,
        taskID: task.taskID,
        input: input,
        message: "当前任务不接受这次 Steer。"
      )
      return
    }
    runWorkbenchMutation(
      requestID: requestID,
      command: BridgeDesktopCommand.steerTask.rawValue,
      taskID: task.taskID,
      input: input
    ) { [weak self] client in
      guard let self else { return false }
      let receipt = try await client.steerTask(
        taskID: task.taskID,
        expectedTurnID: expectedTurnID,
        input: input,
        mode: mode
      )
      await self.refresh(silent: true, includeCatalog: false)
      return receipt.accepted
    }
  }

  public func resumeTask(
    _ task: MCPServiceTaskSnapshot,
    prompt: String? = nil,
    requestID: String? = nil,
    queueIfBusy: Bool = false,
    skillNames: [String]? = nil,
    attachmentPaths: [String] = []
  ) {
    let supportsContinuation = TaskInspectorPresentation.supportsSessionContinuation(
      for: task, providers: agentProviders, installations: agentInstallations
    )
    guard
      TaskInspectorPresentation.canResume(
        task,
        providerSupportsSessionContinuation: supportsContinuation
      ), let sessionID = task.effectiveSessionID
    else {
      rejectWorkbenchCommand(
        requestID: requestID,
        command: BridgeDesktopCommand.resumeTask.rawValue,
        taskID: task.taskID,
        input: prompt,
        message: "当前任务无法续接会话。"
      )
      return
    }
    let trimmedPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
    let continuationPrompt =
      trimmedPrompt.flatMap { $0.isEmpty ? nil : $0 }
      ?? "继续执行未完成的任务"
    submitRetry(
      task: task,
      prompt: continuationPrompt,
      threadID: sessionID,
      successMessage: "已续接任务",
      requestID: requestID,
      command: BridgeDesktopCommand.resumeTask.rawValue,
      receiptInput: prompt ?? "", queueIfBusy: queueIfBusy,
      skillNames: skillNames,
      attachmentPaths: attachmentPaths,
      attachmentSourceTaskID: nil
    )
  }

  public func restartTask(
    _ task: MCPServiceTaskSnapshot, requestID: String? = nil, queueIfBusy: Bool = false,
    skillNames: [String]? = nil,
    attachmentPaths: [String] = []
  ) {
    guard let prompt = task.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
      !prompt.isEmpty
    else {
      rejectWorkbenchCommand(
        requestID: requestID,
        command: BridgeDesktopCommand.restartTask.rawValue,
        taskID: task.taskID,
        input: nil,
        message: "当前任务没有可用于重新开始的原始指令。"
      )
      return
    }
    submitRetry(
      task: task,
      prompt: prompt,
      threadID: nil,
      successMessage: "已重新开始任务",
      requestID: requestID,
      command: BridgeDesktopCommand.restartTask.rawValue,
      receiptInput: nil, queueIfBusy: queueIfBusy,
      skillNames: skillNames,
      attachmentPaths: attachmentPaths,
      attachmentSourceTaskID: task.isCodexTask ? nil : task.taskID
    )
  }

  private func submitRetry(
    task: MCPServiceTaskSnapshot,
    prompt: String,
    threadID: String?,
    successMessage: String,
    requestID: String?,
    command: String,
    receiptInput: String?,
    queueIfBusy: Bool,
    skillNames: [String]?,
    attachmentPaths: [String],
    attachmentSourceTaskID: String?
  ) {
    let request = IPCAgentSubmitRequest(
      projectID: task.projectID,
      providerID: task.providerIdentifier,
      installationID: task.installationID,
      model: task.executionModel,
      effort: TaskRetrySubmission.effort(for: task),
      permissionMode: task.permissionMode,
      prompt: prompt,
      threadID: threadID,
      skillNames: skillNames,
      networkAccess: task.networkAccess,
      modelOverride: TaskRetrySubmission.modelOverride(for: task),
      permissionModeOverride: task.permissionMode != nil,
      clientRequestID: requestID, queueIfBusy: queueIfBusy,
      attachmentPaths: attachmentSourceTaskID == nil && attachmentPaths.isEmpty
        ? nil : attachmentPaths,
      attachmentSourceTaskID: task.isCodexTask ? nil : attachmentSourceTaskID
    )
    runWorkbenchMutation(
      requestID: requestID,
      command: command,
      taskID: task.taskID,
      input: receiptInput
    ) { [weak self] client in
      guard let self else { return false }
      let response = try await client.submitAgentTask(request)
      await self.refresh(silent: true, includeCatalog: false)
      self.openTask(response.taskID)
      self.postToast(successMessage)
      return true
    }
  }

  public func deleteTask(_ taskID: String) {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.deleteTask(taskID: taskID)
      if self.conversation?.taskID == taskID {
        self.closeConversation()
      }
      await self.refresh(silent: true, includeCatalog: false)
      self.postToast("已删除任务记录")
    }
  }

  public func deleteSession(
    _ sessionID: String,
    inProject projectID: String? = nil,
    providerID: String? = nil
  ) {
    let targetProjectID = projectID ?? selectedProjectID
    let targetProviderID = providerID.map(AgentProviderPresentation.identifier)
    let relatedTasks = tasks.filter { task in
      (targetProjectID == nil || task.projectID == targetProjectID)
        && (targetProviderID == nil || task.providerIdentifier == targetProviderID)
        && (task.effectiveSessionID ?? task.taskID) == sessionID
    }
    guard !relatedTasks.isEmpty, relatedTasks.allSatisfy({ $0.isTerminal }) else { return }
    runMutation { [weak self] client in
      guard let self else { return }
      for task in relatedTasks {
        try await client.deleteTask(taskID: task.taskID)
      }
      if let currentTaskID = self.conversation?.taskID,
        relatedTasks.contains(where: { $0.taskID == currentTaskID })
      {
        self.closeConversation()
        self.selectedTaskID = nil
        self.selectedThreadID = nil
      }
      await self.refresh(silent: true, includeCatalog: false)
      self.postToast("已删除会话记录")
    }
  }

}
