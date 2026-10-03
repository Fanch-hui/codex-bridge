import BridgeAgentCore
import BridgeDomain
import Foundation

extension ServiceExecutionCoordinator {
  func expireAgentUserInputs() async {
    let now = Date()
    let expired = pendingAgentUserInputs.values.filter { pending in
      let duration = TimeInterval(pending.request.timeoutSeconds ?? Int(agentApprovalLifetime))
      return now.timeIntervalSince(pending.createdAt) > duration
    }
    for pending in expired {
      await expireAgentUserInput(inputID: pending.approvalID)
    }
  }

  func scheduleAgentUserInputTimeout(_ pending: PendingAgentUserInput) {
    let timeout = pending.request.timeoutSeconds ?? Int(agentApprovalLifetime)
    agentUserInputTimeouts[pending.approvalID] = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(Int64(timeout)))
      } catch {
        return
      }
      await self?.expireAgentUserInput(inputID: pending.approvalID)
    }
  }

  func expireAgentUserInput(inputID: String) async {
    guard let pending = pendingAgentUserInputs.removeValue(forKey: inputID) else { return }
    agentUserInputTimeouts.removeValue(forKey: inputID)
    do {
      try await expireAgentUserInput(pending)
      tasks.changes.publish()
    } catch {
      await failAgentUserInput(
        taskID: pending.request.taskID,
        code: "agent_user_input_timeout_failed",
        summary: "The provider question timed out and could not be cancelled."
      )
    }
  }

  func expireAgentUserInput(_ pending: PendingAgentUserInput) async throws {
    let request = pending.request
    guard let run = activeAgentRuns[request.taskID],
      run.providerID == request.binding.providerID.rawValue,
      run.installationID == request.binding.installationID.rawValue,
      run.providerSessionID == request.binding.providerSessionID,
      run.providerRunID == request.binding.providerRunID,
      let resolveUserInput = run.resolveUserInput
    else {
      throw ExecutionServiceError.bindingMismatch
    }
    _ = try await tasks.resumeAfterAgentUserInput(taskID: request.taskID, cancelled: true)
    do {
      try await resolveUserInput(request.inputID, .cancelled)
    } catch {
      await failAgentUserInput(
        taskID: request.taskID,
        code: "agent_user_input_timeout_failed",
        summary: "The provider question timed out and could not be cancelled."
      )
      throw ExecutionServiceError.processUnavailable
    }
  }

  func failAgentUserInput(taskID: TaskID, code: String, summary: String) async {
    guard !finishedRuns.contains(taskID) else { return }
    finishedRuns.insert(taskID)
    clearAgentUserInputs(taskID: taskID)
    pendingAgentApprovals = pendingAgentApprovals.filter { $0.value.request.taskID != taskID }
    if let run = activeAgentRuns.removeValue(forKey: taskID) {
      await run.shutdown()
    }
    _ = await conversation.close(taskID: taskID)
    _ = try? await tasks.fail(taskID: taskID, failureCode: code, summary: summary)
  }
}
