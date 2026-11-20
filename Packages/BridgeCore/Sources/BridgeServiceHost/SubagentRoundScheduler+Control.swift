import BridgeServiceCore
import Foundation

/// Stops and cancellations. Each plans under the lane, then aborts live dispatches and tells tasks
/// to stop outside it: a live dispatch records its own outcome through the lane, so waiting for it
/// while holding the lane would never finish.
extension SubagentRoundScheduler {
  private struct ControlPlan {
    var abort: [Task<Void, Never>] = []
    var stops: [(key: SubagentRoundKey, taskID: String?)] = []
  }

  // MARK: - One child

  /// Node `stop(child)`: cancels the queued rounds, aborts a dispatch in progress, or tells the
  /// running task to stop. A stop that cannot be confirmed because the outcome of the aborted
  /// dispatch is still being checked fails with `outcomeStillBeingChecked`.
  func stopChild(
    rootID: String, childID: String, expectedTaskID: String? = nil, expectedRunID: String? = nil
  ) async throws {
    guard !isShutDown else { throw SubagentSchedulerError.shutDown }
    let (plan, control) = try await withLane(rootID) {
      try await planStop(
        rootID: rootID, childID: childID, expectedTaskID: expectedTaskID,
        expectedRunID: expectedRunID)
    }
    if let aborted = plan.abortLiveRound {
      await abort(control.abort)
      if plan.failsIfOutcomeStaysUnknown {
        try await requireOutcomeKnown(aborted)
      }
    }
    try await stop(control.stops)
    kick(rootID)
  }

  private func planStop(
    rootID: String, childID: String, expectedTaskID: String?, expectedRunID: String?
  ) async throws -> (SubagentStopPlan, ControlPlan) {
    let rounds = try await ledger.rounds(rootID: rootID)
    let hasRounds = rounds.contains { $0.key.childID == childID }
    try await requireChildAvailable(childID, rootID: rootID, hasRounds: hasRounds)
    let snapshots = await readSnapshots(
      rootID: rootID, rounds: Self.childSnapshotTargets(rounds, childID: childID))
    let planner = SubagentRoundPlanner(rootID: rootID, rounds: rounds, snapshots: snapshots)
    let plan = try planner.planStop(
      childID: childID, expectedTaskID: expectedTaskID, expectedRunID: expectedRunID,
      liveRequestIDs: liveRequestIDs())
    try await cancel(plan.cancelQueued, in: rounds)
    var control = ControlPlan()
    if plan.abortLiveRound != nil, let dispatch = live[childID] { control.abort = [dispatch.task] }
    if let key = plan.stopRound { control.stops = [(key, taskID(of: key, in: rounds))] }
    return (plan, control)
  }

  private func requireOutcomeKnown(_ key: SubagentRoundKey) async throws {
    let rounds = try await ledger.rounds(rootID: key.rootID)
    if rounds.first(where: { $0.key == key })?.phase == .unknown {
      throw SubagentRoundRejection.outcomeStillBeingChecked
    }
  }

  // MARK: - One request

  /// Node `cancelInput`: withdraws a queued request, aborts the dispatch of one in progress, or
  /// tells the task of a running one to stop. Answers with the resulting state.
  func cancelInput(rootID: String, childID: String, requestID: String) async throws
    -> SubagentCancelInputState
  {
    guard !isShutDown else { throw SubagentSchedulerError.shutDown }
    let key = SubagentRoundKey(rootID: rootID, childID: childID, requestID: requestID)
    let (plan, control) = try await withLane(rootID) {
      let rounds = try await ledger.rounds(rootID: rootID)
      let snapshots = await readSnapshots(
        rootID: rootID, rounds: Self.childSnapshotTargets(rounds, childID: childID))
      let plan = SubagentRoundPlanner(rootID: rootID, rounds: rounds, snapshots: snapshots)
        .planCancelInput(
          childID: childID, requestID: requestID, isSending: isSending(key),
          liveRequestIDs: liveRequestIDs())
      try await cancel(plan.cancelQueued.map { [$0] } ?? [], in: rounds)
      var control = ControlPlan()
      if plan.abortLiveRound, let dispatch = live[childID] { control.abort = [dispatch.task] }
      if let stopKey = plan.stopRound {
        control.stops = [(stopKey, taskID(of: stopKey, in: rounds))]
      }
      return (plan, control)
    }
    await abort(control.abort)
    try await stop(control.stops)
    kick(rootID)
    return plan.state
  }

  // MARK: - The whole root

  /// Node `stopRoot`: cancels what is queued, aborts the dispatches in progress and tells every
  /// task to stop. A task that cannot be stopped does not keep the others from being stopped;
  /// the failures are reported together.
  func stopRoot(rootID: String) async throws {
    guard !isShutDown else { throw SubagentSchedulerError.shutDown }
    let control = try await withLane(rootID) {
      let rounds = try await ledger.rounds(rootID: rootID)
      let plan = SubagentRoundPlanner(rootID: rootID, rounds: rounds)
        .planStopRoot(liveRequestIDs: liveRequestIDs())
      try await cancel(plan.cancelQueued, in: rounds)
      var control = ControlPlan()
      control.abort = plan.abortLiveRounds.compactMap { live[$0.childID]?.task }
      control.stops = plan.stopRounds.map { ($0, taskID(of: $0, in: rounds)) }
      return control
    }
    await abort(control.abort)
    let failures = await stopAll(control.stops)
    kick(rootID)
    if !failures.isEmpty { throw SubagentSchedulerError.stopFailed(failures) }
  }

  // MARK: - Shared steps

  private func cancel(_ keys: [SubagentRoundKey], in rounds: [SubagentRound]) async throws {
    for key in keys {
      guard let round = rounds.first(where: { $0.key == key }), round.phase == .queued else {
        continue
      }
      _ = try await transition(round, to: .cancelled)
    }
  }

  private func taskID(of key: SubagentRoundKey, in rounds: [SubagentRound]) -> String? {
    rounds.first { $0.key == key }?.taskID
  }

  /// Cancels the dispatch tasks and waits until each has recorded its outcome.
  private func abort(_ dispatches: [Task<Void, Never>]) async {
    for task in dispatches { task.cancel() }
    for task in dispatches { await task.value }
  }

  private func stop(_ stops: [(key: SubagentRoundKey, taskID: String?)]) async throws {
    for stop in stops { try await tasks.stop(stop.key, taskID: stop.taskID) }
  }

  private func stopAll(_ stops: [(key: SubagentRoundKey, taskID: String?)]) async
    -> [SubagentStopFailure]
  {
    var failures: [SubagentStopFailure] = []
    for stop in stops {
      do {
        try await tasks.stop(stop.key, taskID: stop.taskID)
      } catch is CancellationError {
        break
      } catch {
        failures.append(
          SubagentStopFailure(
            childID: stop.key.childID, requestID: stop.key.requestID, message: describe(error)))
      }
    }
    return failures
  }
}
