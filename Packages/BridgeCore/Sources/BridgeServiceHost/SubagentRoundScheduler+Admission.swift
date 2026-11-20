import BridgeServiceCore
import Foundation

extension SubagentRoundScheduler {
  /// The queued rounds that may be considered now: the next one of every child that is not busy.
  func scheduleQueued(_ planner: SubagentRoundPlanner) async {
    for round in planner.dispatchCandidates(busyChildren: Set(live.keys)) {
      await attempt(round, "schedule") { try await advance(round, planner: planner) }
    }
  }

  private func advance(_ round: SubagentRound, planner: SubagentRoundPlanner) async throws {
    switch planner.readiness(of: round) {
    case .ready:
      if !round.dependencies.isEmpty { await announceDependencies(round, []) }
      try await admit(round)
    case .failed(let reason):
      try await fail(round, origin: .dependency, reason: reason)
    case .inconsistent(let message):
      await reportOnce(
        Self.reportKey("schedule", round), rootID: round.key.rootID, message: message)
    case .waitingForDependencies(let pending):
      await announceDependencies(round, pending)
    case .waitingForPreviousRound(let status):
      try await noteWaiting(round, status: status)
    case .yielding(let status):
      try await noteWaiting(round, status: status)
    }
  }

  /// Records the workspace status a continuation waits on (a merge in progress or a conflict).
  private func noteWaiting(_ round: SubagentRound, status: SubagentWorkspaceStatus?) async throws {
    guard let status, round.waitingReason != status.rawValue else { return }
    guard try await transition(round, { $0.waitingReason = status.rawValue }) != nil else { return }
    await announceWaiting(round, workspaceStatus: status.rawValue)
  }

  // MARK: - Admission

  /// Admission before the dispatch. An error that may pass leaves the round queued for the next
  /// pass; any other error ends the round as failed, with the error as the reason. Nothing was
  /// dispatched yet, so the controller can safely delegate again.
  private func admit(_ round: SubagentRound) async throws {
    do {
      try await admission(round)
    } catch {
      guard !Self.isRetryable(error) else { throw error }
      try await fail(round, origin: .dispatch, reason: describe(error))
    }
  }

  static func isRetryable(_ error: any Error) -> Bool {
    error is CancellationError || error is SubagentTransientError
  }

  /// Node `ExternalWorkspaceAdmission.begin`: a read-only round needs nothing; a writer reserves
  /// capacity and, unless its writes are gated per tool call, takes the task-long write lease.
  /// The flags are recorded before the call that sets them, so a crash in between leaves
  /// something the pass releases instead of an orphan.
  private func admission(_ round: SubagentRound) async throws {
    if try await readsOnly(round) {
      try await startDispatch(round, mode: .readOnly, scope: nil)
      return
    }
    guard
      var current = try await record(
        round, scope: round.writeScope, lease: round.leaseHeld, reservation: true)
    else { return }
    switch try await workspace.reserve(current) {
    case .waiting:
      try await wait(current, reason: Self.capacityReason)
      return
    case .reserved(let scope):
      let takesLease = scope != .tool
      guard
        let scoped = try await record(current, scope: scope, lease: takesLease, reservation: true)
      else { return }
      current = scoped
      if takesLease, try await acquireLease(current) == .waiting {
        try await wait(current, reason: Self.leaseReason)
        return
      }
    }
    try await startDispatch(current, mode: .shared, scope: current.writeScope)
  }

  /// A child narrowed to read-only never writes, whatever its root may do.
  private func readsOnly(_ round: SubagentRound) async throws -> Bool {
    if round.access == .readOnly { return true }
    return try await workspace.rootIsReadOnly(rootID: round.key.rootID)
  }

  static let capacityReason = "capacity"
  static let leaseReason = "lease"

  private func acquireLease(_ round: SubagentRound) async throws -> SubagentLeaseGrant {
    try await leases.acquire(rootID: round.key.rootID, ownerID: Self.leaseOwner(round.key))
  }

  /// Writes the admission state of a queued round when it differs from what is stored, and drops
  /// a stale merge-wait reason now that the round is ready.
  private func record(
    _ round: SubagentRound, scope: SubagentWriteScope?, lease: Bool, reservation: Bool
  ) async throws -> SubagentRound? {
    var wanted = round
    wanted.workspaceMode = .shared
    wanted.writeScope = scope
    wanted.leaseHeld = lease
    wanted.reservationHeld = reservation
    if let reason = round.waitingReason, reason != Self.capacityReason, reason != Self.leaseReason {
      wanted.waitingReason = nil
    }
    guard wanted != round else { return round }
    let target = wanted
    return try await transition(round) {
      $0.workspaceMode = target.workspaceMode
      $0.writeScope = target.writeScope
      $0.leaseHeld = target.leaseHeld
      $0.reservationHeld = target.reservationHeld
      $0.waitingReason = target.waitingReason
    }
  }

  private func wait(_ round: SubagentRound, reason: String) async throws {
    guard round.waitingReason != reason else { return }
    _ = try await transition(round) { $0.waitingReason = reason }
  }

  // MARK: - Dispatch

  private func startDispatch(
    _ round: SubagentRound, mode: SubagentWorkspaceMode, scope: SubagentWriteScope?
  ) async throws {
    guard let reserved = try await transition(round, { $0.reservationHeld = true }) else { return }
    guard try await workspace.reserveExecution(reserved) else {
      try await wait(reserved, reason: Self.capacityReason)
      return
    }
    guard
      let stored = try await transition(
        reserved, to: .dispatching,
        {
          $0.workspaceMode = mode
          $0.writeScope = scope
        })
    else { return }
    guard let prompt = stored.prompt else { throw ServiceStoreError.corruptRecord }
    launch(stored, prompt: prompt)
  }

  /// The slow part runs in its own task, outside the lane, so other children and roots keep
  /// going. The task owns the round until `finishDispatch` has recorded its outcome.
  private func launch(_ round: SubagentRound, prompt: String) {
    let task = Task { [self] in
      let outcome: Result<SubagentDispatchReceipt, any Error>
      do {
        outcome = .success(try await dispatch(round, prompt: prompt))
      } catch {
        outcome = .failure(error)
      }
      await finishDispatch(round, outcome)
    }
    live[round.key.childID] = LiveDispatch(key: round.key, task: task)
  }

  private func dispatch(_ round: SubagentRound, prompt: String) async throws
    -> SubagentDispatchReceipt
  {
    switch round.kind {
    case .start: return try await tasks.dispatchFirst(round, prompt: prompt)
    case .send: return try await tasks.dispatchContinuation(round, prompt: prompt)
    case .steer: throw SubagentRoundRejection.unsupportedDelivery
    }
  }

  private func finishDispatch(
    _ round: SubagentRound, _ outcome: Result<SubagentDispatchReceipt, any Error>
  ) async {
    let rootID = round.key.rootID
    do {
      try await withLane(rootID) {
        do {
          try await recordOutcome(outcome, of: round)
        } catch {
          live[round.key.childID] = nil
          throw error
        }
        live[round.key.childID] = nil
      }
    } catch {
      await reportOnce("dispatch:\(round.key.requestID)", rootID: rootID, message: describe(error))
    }
    kick(rootID)
  }

  /// A receipt moves the round to `running`. An error moves it to `unknown`: the request may or
  /// may not have reached Bridge, so the next pass asks `probe` instead of guessing.
  private func recordOutcome(
    _ outcome: Result<SubagentDispatchReceipt, any Error>, of round: SubagentRound
  ) async throws {
    switch outcome {
    case .success(let receipt) where !receipt.taskID.isEmpty:
      guard
        let stored = try await transition(
          round, to: .running,
          {
            $0.taskID = receipt.taskID
            $0.workspaceMode = Self.adoptedMode(receipt.workspaceMode, current: $0.workspaceMode)
          })
      else { return }
      await announceStarted(stored, state: receipt.state)
    case .success:
      _ = try await transition(
        round, to: .unknown, { $0.dispatchError = "Bridge returned an invalid subagent receipt" })
    case .failure(let error):
      let reason = String(describe(error).prefix(2_000))
      _ = try await transition(round, to: .unknown, { $0.dispatchError = reason })
    }
  }
}
