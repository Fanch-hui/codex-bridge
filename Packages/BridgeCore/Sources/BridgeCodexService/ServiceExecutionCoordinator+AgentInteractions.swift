import BridgeAgentCore
import BridgeDomain
import Foundation

extension ServiceExecutionCoordinator {
  func acquireAgentInteraction(_ taskID: TaskID) async {
    if agentInteractionOwners.insert(taskID).inserted { return }
    await withCheckedContinuation { continuation in
      agentInteractionWaiters[taskID, default: []].append(continuation)
    }
  }

  func releaseAgentInteraction(_ taskID: TaskID) {
    guard var waiters = agentInteractionWaiters[taskID], !waiters.isEmpty else {
      agentInteractionOwners.remove(taskID)
      return
    }
    let next = waiters.removeFirst()
    agentInteractionWaiters[taskID] = waiters.isEmpty ? nil : waiters
    next.resume()
  }

  func waitForAgentCancellation(_ taskID: TaskID, after version: UInt64) async {
    guard agentCancellationVersions[taskID, default: 0] == version,
      activeAgentRuns[taskID] != nil, !finishedRuns.contains(taskID)
    else { return }
    await withCheckedContinuation { continuation in
      agentCancellationWaiters[taskID, default: []].append(continuation)
    }
  }

  func acknowledgeAgentCancellation(_ taskID: TaskID) {
    agentCancellationVersions[taskID, default: 0] &+= 1
    for waiter in agentCancellationWaiters.removeValue(forKey: taskID) ?? [] {
      waiter.resume()
    }
  }

  func cancelAgentInteractions(
    taskID: TaskID, approvalIDs: [String], userInputIDs: [String]
  ) async throws {
    defer { acknowledgeAgentCancellation(taskID) }
    var removedApproval = false
    for id in approvalIDs where pendingAgentApprovals[id]?.request.taskID == taskID {
      pendingAgentApprovals.removeValue(forKey: id)
      removedApproval = true
    }
    let cancelledInputIDs = Set(userInputIDs)
    let keys = pendingAgentUserInputs.compactMap { key, pending in
      pending.request.taskID == taskID && cancelledInputIDs.contains(pending.request.inputID)
        ? key : nil
    }
    for key in keys {
      agentUserInputTimeouts.removeValue(forKey: key)?.cancel()
      pendingAgentUserInputs.removeValue(forKey: key)
    }
    guard removedApproval || !keys.isEmpty,
      !pendingAgentApprovals.values.contains(where: { $0.request.taskID == taskID }),
      !pendingAgentUserInputs.values.contains(where: { $0.request.taskID == taskID }),
      let task = try await tasks.task(id: taskID), task.state.status == .waitingForCodexApproval
    else { return }
    if !keys.isEmpty {
      _ = try await tasks.resumeAfterAgentUserInput(taskID: taskID, cancelled: true)
    } else {
      _ = try await tasks.resumeAfterCodexApproval(taskID: taskID, approved: false)
    }
    tasks.changes.publish()
  }
}
