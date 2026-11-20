import Foundation

extension SubagentRoundPlanner {
  /// Node `AgentInputs.sendNew`: decides between steering the running task and queueing a
  /// continuation, and builds the round to record for either.
  func admitNewSend(
    _ request: SubagentSendRequest, binding: SubagentRound, fingerprint: String
  ) throws -> SubagentSendAdmission {
    let childID = request.childID
    let active = activeRun(of: childID)
    var delivery = request.delivery
    if delivery == .auto && request.repairConflict { delivery = .queue }
    if delivery == .auto {
      var canSteer = false
      if let active, request.attachmentPaths.isEmpty {
        canSteer = try requiredSnapshot(of: active).canSteer == true
      }
      delivery = canSteer ? .steer : .queue
    }
    if delivery == .steer {
      return try admitSteer(request, binding: binding, fingerprint: fingerprint, active: active)
    }
    let current = active ?? currentRun(of: childID)
    if let current, let snapshot = snapshot(of: current) {
      let mode = snapshot.workspaceMode ?? current.workspaceMode
      let waitingForMerge =
        mode == .isolated && Self.mergePendingStatuses.contains(snapshot.workspaceStatus)
      if snapshot.supportsContinue == false
        || (snapshot.state.isTerminal && snapshot.canContinue == false && !waitingForMerge)
      {
        throw SubagentRoundRejection.cannotContinue
      }
    }
    try assertCurrent(
      childID: childID, expectedTaskID: request.expectedTaskID, expectedRunID: request.expectedRunID
    )
    return .enqueue(newDraft(request, binding: binding, fingerprint: fingerprint, steer: false))
  }

  /// Workspace statuses in which an isolated child still waits for its changes to merge; `nil`
  /// is a snapshot without a status.
  private static let mergePendingStatuses: [SubagentWorkspaceStatus?] = [
    nil, .pending, .conflict, "validation_required", "recovery_required",
  ]

  private func admitSteer(
    _ request: SubagentSendRequest, binding: SubagentRound, fingerprint: String,
    active: SubagentRound?
  ) throws -> SubagentSendAdmission {
    guard let active, let taskID = active.taskID else { throw SubagentRoundRejection.notRunning }
    guard request.attachmentPaths.isEmpty else {
      throw SubagentRoundRejection.attachmentsWhileRunning
    }
    guard try requiredSnapshot(of: active).canSteer == true else {
      throw SubagentRoundRejection.cannotSteer
    }
    try assertCurrent(
      childID: request.childID, expectedTaskID: request.expectedTaskID,
      expectedRunID: request.expectedRunID)
    return .steer(
      newDraft(request, binding: binding, fingerprint: fingerprint, steer: true), taskID: taskID)
  }

  private func requiredSnapshot(of round: SubagentRound) throws -> SubagentTaskSnapshot {
    guard let snapshot = snapshot(of: round) else {
      throw SubagentRoundRejection.snapshotUnavailable(taskID: round.taskID ?? "")
    }
    return snapshot
  }

  private func newDraft(
    _ request: SubagentSendRequest, binding: SubagentRound, fingerprint: String, steer: Bool
  ) -> SubagentRoundDraft {
    let previous =
      request.repairConflict
      ? (latest(of: request.childID) { $0.taskID != nil && !$0.isSteer } ?? binding) : binding
    let previousRunID = snapshot(of: previous)?.runID
    return SubagentRoundDraft(
      key: SubagentRoundKey(
        rootID: rootID, childID: request.childID, requestID: request.requestID),
      projectID: binding.projectID, parentSessionID: binding.parentSessionID,
      installationID: binding.installationID, kind: steer ? .steer : .send,
      fingerprint: fingerprint, prompt: steer ? nil : request.prompt,
      options: SubagentRoundOptions(
        attachmentPaths: request.attachmentPaths, label: binding.options.label),
      access: binding.access, repairConflict: request.repairConflict,
      previousRequestID: previous.key.requestID,
      previousTaskID: request.expectedTaskID.flatMap { $0 == previous.taskID ? $0 : nil },
      previousRunID: request.expectedRunID.flatMap { $0 == previousRunID ? $0 : nil },
      requestedAfterTerminal: isTerminal(previous), childCreatedAt: binding.childCreatedAt,
      createdAt: request.createdAt)
  }
}
