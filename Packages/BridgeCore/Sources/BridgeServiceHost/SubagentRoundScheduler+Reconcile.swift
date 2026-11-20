import BridgeServiceCore
import Foundation

extension SubagentRoundScheduler {
  // MARK: - Unconfirmed dispatches

  /// Settles rounds whose dispatch has no known outcome: found after a restart, or after a
  /// dispatch that failed ambiguously. The probe by request ID tells whether Bridge ever got
  /// the request; a steer is never resent.
  func resolveUnconfirmed(_ planner: SubagentRoundPlanner, rootStopped: Bool) async {
    let liveRequests = liveRequestIDs()
    for round in planner.rounds where round.phase.isUnconfirmed {
      let isLive = liveRequests[round.key.childID] == round.key.requestID
      guard !isLive || round.phase == .unknown, !isSending(round.key) else { continue }
      await attempt(round, "resolve") {
        let probe = try await tasks.probe(round.key)
        let action = planner.reconcile(
          round, probe: probe, rootStopped: rootStopped, isSending: false, isLive: isLive)
        try await apply(action, to: round)
      }
    }
  }

  private func apply(_ action: SubagentReconciliation, to round: SubagentRound) async throws {
    switch action {
    case .none, .requeue:
      return
    case .markDeliveryUnknown(let taskID):
      guard
        try await transition(
          round, to: .deliveryUnknown, { if let taskID { $0.taskID = taskID } }) != nil
      else { return }
      await events.emit(
        sessionID: round.parentSessionID, type: "subagent.input-unknown",
        payload: Self.object(
          [
            "childID": round.key.childID, "requestID": round.key.requestID,
            "taskID": taskID ?? round.taskID,
          ]))
    case .failNotDispatched(let reason):
      try await fail(round, origin: .dispatch, reason: reason)
    case .taskFound(let adopt, let stopped):
      try await foundTask(round, adopt: adopt, whileStopped: stopped)
    case .inconsistent(let message):
      throw SubagentRoundRejection.snapshotUnavailable(taskID: message)
    }
  }

  private func foundTask(
    _ round: SubagentRound, adopt: Bool, whileStopped: SubagentStoppedTaskAction?
  ) async throws {
    var current = round
    if adopt {
      let found = try await tasks.recoveredSnapshot(round.key)
      guard round.taskID == nil || round.taskID == found.taskID else {
        throw SubagentSchedulerError.taskMismatch
      }
      let next: SubagentRoundPhase = round.isSteer ? .attached : .running
      guard
        let stored = try await transition(
          round, to: next,
          {
            $0.taskID = found.taskID
            $0.workspaceMode = Self.adoptedMode(found.workspaceMode, current: $0.workspaceMode)
          })
      else { return }
      current = stored
      await announceStarted(stored, state: found.state.rawValue)
    }
    switch whileStopped {
    case .stopTask:
      try await tasks.stop(current.key, taskID: current.taskID)
    case .settleInterrupted:
      if current.phase == .running { _ = try await transition(current, to: .settled) }
    case nil:
      break
    }
  }

  /// A read-only round stays read-only whatever mode Bridge reports for the child.
  static func adoptedMode(
    _ reported: SubagentWorkspaceMode?, current: SubagentWorkspaceMode?
  ) -> SubagentWorkspaceMode? {
    current == .readOnly ? .readOnly : (reported ?? current)
  }

  /// A round that never reached Bridge ends as failed; the reason becomes the delivered notice.
  func fail(
    _ round: SubagentRound, origin: SubagentFailureOrigin, reason: String?
  ) async throws {
    guard
      let stored = try await transition(
        round, to: .failed,
        {
          $0.failureOrigin = origin
          $0.failureReason = reason
        })
    else { return }
    await announceFailure(stored)
  }

  // MARK: - Held resources

  /// Gives back what a round no longer needs. A round holds a capacity slot and a task-long write
  /// lease only while they matter; releasing is idempotent, so a failed release is simply tried
  /// again on the next pass.
  func releaseUnneeded(_ planner: SubagentRoundPlanner) async {
    for round in planner.rounds where round.reservationHeld || round.leaseHeld {
      let keep = Self.heldResources(
        of: round, terminal: planner.isTerminal(round),
        hasSnapshot: planner.snapshot(of: round) != nil)
      await attempt(round, "release") {
        var current = round
        if current.leaseHeld, !keep.lease, adapterReady {
          try await leases.release(
            rootID: round.key.rootID, ownerID: Self.leaseOwner(round.key))
          guard let stored = try await transition(current, { $0.leaseHeld = false }) else { return }
          current = stored
        }
        if current.reservationHeld, !keep.reservation {
          try await releaseReservation(current)
        }
      }
    }
  }

  private func releaseReservation(_ round: SubagentRound) async throws {
    guard try await workspace.releaseReservation(round.key) == .released else { return }
    _ = try await transition(round, { $0.reservationHeld = false })
  }

  /// What a round has to keep holding. While it is still being admitted or its outcome is
  /// unknown the flags stay as they are; the probe decides. After dispatch a shared writer keeps
  /// only its lease and an isolated one only its slot; a finished round keeps nothing.
  static func heldResources(
    of round: SubagentRound, terminal: Bool, hasSnapshot: Bool
  ) -> (reservation: Bool, lease: Bool) {
    switch round.phase {
    case .queued, .dispatching, .unknown:
      return (round.reservationHeld, round.leaseHeld)
    case .running:
      guard hasSnapshot, !terminal else { return (round.reservationHeld, round.leaseHeld) }
      return (true, round.workspaceMode == .shared && round.writeScope != .tool)
    case .settled, .failed, .cancelled, .attached, .deliveryUnknown:
      return (false, false)
    }
  }

  // MARK: - Stopped root

  /// Nothing new starts while the root is stopped.
  func cancelQueued(_ rounds: [SubagentRound]) async {
    for round in rounds where round.phase == .queued {
      await attempt(round, "cancel") { _ = try await transition(round, to: .cancelled) }
    }
  }
}
