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
    mode: MCPTaskSteerMode = .queued
  ) {
    guard let expectedTurnID = task.expectedControlID,
      !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      input.utf8.count <= IPCTaskSteerRequest.maximumInputBytes,
      !input.contains("\0")
    else { return }
    runMutation { [weak self] client in
      guard let self else { return }
      _ = try await client.steerTask(
        taskID: task.taskID,
        expectedTurnID: expectedTurnID,
        input: input,
        mode: mode
      )
      await self.refresh(silent: true, includeCatalog: false)
    }
  }

  public func resumeTask(
    _ task: MCPServiceTaskSnapshot,
    prompt: String? = nil
  ) {
    let supportsContinuation =
      task.isCodexTask
      || task.providerID.flatMap { providerID in
        agentProviders.first(where: { $0.providerID == providerID })?.supportsSessionContinuation
      } == true
    guard
      TaskInspectorPresentation.canResume(
        task,
        providerSupportsSessionContinuation: supportsContinuation
      ), let sessionID = task.effectiveSessionID
    else { return }
    let trimmedPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
    let continuationPrompt =
      trimmedPrompt.flatMap { $0.isEmpty ? nil : $0 }
      ?? "继续执行未完成的任务"
    submitRetry(
      task: task,
      prompt: continuationPrompt,
      threadID: sessionID,
      successMessage: "已续接任务"
    )
  }

  public func restartTask(_ task: MCPServiceTaskSnapshot) {
    guard let prompt = task.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
      !prompt.isEmpty
    else { return }
    submitRetry(
      task: task,
      prompt: prompt,
      threadID: nil,
      successMessage: "已重新开始任务"
    )
  }

  private func submitRetry(
    task: MCPServiceTaskSnapshot,
    prompt: String,
    threadID: String?,
    successMessage: String
  ) {
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
      modelOverride: task.executionModel != nil,
      permissionModeOverride: task.permissionMode != nil
    )
    runMutation { [weak self] client in
      guard let self else { return }
      let response = try await client.submitAgentTask(request)
      await self.refresh(silent: true, includeCatalog: false)
      self.openTask(response.taskID)
      self.postToast(successMessage)
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
