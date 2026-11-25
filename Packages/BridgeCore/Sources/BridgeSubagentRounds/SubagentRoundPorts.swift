import BridgeACP
import BridgeServiceCore
import Foundation

// The scheduler talks to the rest of the service only through these ports, so it can be tested
// with fakes and never knows about the engine, the controller or the legacy subagent tables.
// "Root" is the controller that owns a child; the production wiring maps it to an engine session.

/// Persistence of the round ledger. The ledger is the single source of truth for what a round is.
package protocol SubagentRoundLedger: Sendable {
  func rounds(rootID: String) async throws -> [SubagentRound]
  func insert(_ draft: SubagentRoundDraft) async throws -> SubagentRoundInsertion
  /// Compare-and-set on the phase; see `SimpleServiceStore.updateSubagentRound`.
  func update(
    _ key: SubagentRoundKey, expected: SubagentRoundPhase, to next: SubagentRoundPhase?,
    mutate: @Sendable (inout SubagentRound) throws -> Void
  ) async throws -> SubagentRoundUpdateOutcome
  /// Marks the result delivered and keeps the older result bookkeeping in step, atomically.
  func markDelivered(_ key: SubagentRoundKey) async throws -> SubagentRoundUpdateOutcome
  /// Roots with work left to do (also holding a reservation or lease, or an undelivered result).
  func openRoots() async throws -> [String]
  func allRoots() async throws -> [String]
  /// Every root that has rounds for this child; used to tell a foreign child from an unknown one.
  func roots(ofChild childID: String) async throws -> [String]
  func retire(rootID: String, now: Date, busy: Set<SubagentRoundKey>) async throws
    -> SubagentRetirement
}

/// What a dispatch (or steer) returned. `state` is the task state as Bridge reported it.
package struct SubagentDispatchReceipt: Equatable, Sendable {
  var taskID: String
  var state: String
  var workspaceMode: SubagentWorkspaceMode?

  package init(taskID: String, state: String, workspaceMode: SubagentWorkspaceMode? = nil) {
    self.taskID = taskID
    self.state = state
    self.workspaceMode = workspaceMode
  }
}

/// The finished (or failed) outcome of a task as it is delivered to the controller.
package struct SubagentTaskResult: Equatable, Sendable {
  var state: String
  var output: String?
  var error: String?
  /// Workspace fields (`workspaceMode`, `workspaceStatus`, `changedFiles`, ...) to pass on as-is.
  var workspace: [String: ACPJSONValue]

  package init(
    state: String, output: String? = nil, error: String? = nil,
    workspace: [String: ACPJSONValue] = [:]
  ) {
    self.state = state
    self.output = output
    self.error = error
    self.workspace = workspace
  }
}

/// A task snapshot together with the fields the page lists for the child (`runID`,
/// `capabilities`, `changedFiles`, ...), exactly as the task reported them.
package struct SubagentTaskView: Equatable, Sendable {
  package let snapshot: SubagentTaskSnapshot
  var fields: [String: ACPJSONValue]

  package init(snapshot: SubagentTaskSnapshot, fields: [String: ACPJSONValue]) {
    self.snapshot = snapshot
    self.fields = fields
  }
}

/// Everything about subagent tasks. Reads reuse the in-process task and workspace records.
package protocol SubagentTaskPort: Sendable {
  /// Starts the child. A definite refusal throws; an ambiguous failure throws as well, and the
  /// scheduler then asks `probe`.
  func dispatchFirst(_ round: SubagentRound, prompt: String) async throws -> SubagentDispatchReceipt
  /// Queues a continuation of a finished task.
  func dispatchContinuation(_ round: SubagentRound, prompt: String) async throws
    -> SubagentDispatchReceipt
  /// Delivers an instruction to the running task. Never called twice for one round.
  func steer(_ round: SubagentRound, taskID: String, prompt: String) async throws
    -> SubagentDispatchReceipt
  /// A lean snapshot of one task (no message history).
  func snapshot(rootID: String, childID: String, taskID: String) async throws
    -> SubagentTaskSnapshot
  /// `snapshot` plus the listing fields; ports that have none leave them out.
  func view(rootID: String, childID: String, taskID: String) async throws -> SubagentTaskView
  /// The task of a request whose dispatch was unconfirmed, found by request ID.
  func recoveredSnapshot(_ key: SubagentRoundKey) async throws -> SubagentTaskSnapshot
  func probe(_ key: SubagentRoundKey) async throws -> SubagentProbe
  /// Tells the task to stop. `taskID` is nil for a round whose task is not known yet.
  func stop(_ key: SubagentRoundKey, taskID: String?) async throws
  func result(of key: SubagentRoundKey, taskID: String) async throws -> SubagentTaskResult
  /// The child exists in the older subagent bookkeeping.
  func isLegacyChild(rootID: String, childID: String) async throws -> Bool
}

extension SubagentTaskPort {
  package func view(rootID: String, childID: String, taskID: String) async throws
    -> SubagentTaskView
  {
    SubagentTaskView(
      snapshot: try await snapshot(rootID: rootID, childID: childID, taskID: taskID), fields: [:])
  }
}

package enum SubagentReservation: Equatable, Sendable {
  /// A capacity slot is held. `tool` writers are gated per tool call and need no task-long lease.
  case reserved(SubagentWriteScope)
  case waiting
}

package enum SubagentReservationRelease: Equatable, Sendable {
  case released
  /// The slot is still in use; the flag stays.
  case stillHeld
}

package protocol SubagentWorkspacePort: Sendable {
  func reserveExecution(_ round: SubagentRound) async throws -> Bool
  /// The root only reads, so its children never write either.
  func rootIsReadOnly(rootID: String) async throws -> Bool
  func reserve(_ round: SubagentRound) async throws -> SubagentReservation
  func releaseReservation(_ key: SubagentRoundKey) async throws -> SubagentReservationRelease
}

package enum SubagentLeaseGrant: Equatable, Sendable {
  case granted
  /// Queued behind another writer; the port reports the grant through `SubagentRoundScheduler.kick`.
  case waiting
}

/// The task-long write lease of a round. Neither call waits for another writer.
package protocol SubagentLeasePort: Sendable {
  func acquire(rootID: String, ownerID: String) async throws -> SubagentLeaseGrant
  /// Frees a held lease or withdraws a queued request; safe when neither exists.
  func release(rootID: String, ownerID: String) async throws
  /// Re-creates the lease of a dispatched round whose holder record is missing.
  func recover(rootID: String, ownerID: String) async throws
}

package enum SubagentRootHold: Equatable, Sendable {
  case held
  case stopped
}

/// Keeps the root open while it has subagent work; the root's own agent may be idle meanwhile.
package protocol SubagentRootPort: Sendable {
  func isStopped(rootID: String) async throws -> Bool
  /// Idempotent: the scheduler repeats it on every pass while it needs the root.
  func hold(rootID: String, holdID: String) async throws -> SubagentRootHold
  func release(rootID: String, holdID: String) async throws
  /// Tells the controlling adapter that the root has results to deliver. The adapter also asks on
  /// its own now and then, so a lost notice only delays a delivery.
  /// Returns whether the adapter took the notice.
  func announceResults(rootID: String) async -> Bool
}

extension SubagentRootPort {
  package func announceResults(rootID: String) async -> Bool { true }
}

package protocol SubagentEventSink: Sendable {
  /// `sessionID` is the session the page shows the event under (the round's parent).
  func emit(sessionID: String, type: String, payload: ACPJSONValue) async
  /// A pass or dispatch failed in a way the scheduler cannot resolve itself; it retries later.
  func report(rootID: String, message: String) async
}

/// A failure that may pass on its own (busy database, engine restarting). The scheduler keeps the
/// round and tries again; any other error from admission ends the round as failed.
package struct SubagentTransientError: Error {
  package let underlying: any Error

  package init(underlying: any Error) { self.underlying = underlying }
}

package enum SubagentSchedulerError: Error, Equatable {
  /// The child was created by the older subagent bookkeeping and has no rounds yet.
  case legacyChildRequiresMigration(childID: String)
  case unknownRound
  case taskMismatch
  case notFinished
  case stopFailed([SubagentStopFailure])
  case shutDown

  package var message: String {
    switch self {
    case .legacyChildRequiresMigration(let childID):
      "Subagent \(childID) predates the round ledger; migrate it before using round operations"
    case .unknownRound: "Subagent request not found"
    case .taskMismatch: "The subagent request belongs to another task"
    case .notFinished: "The subagent result is not final yet"
    case .stopFailed(let failures):
      "Failed to stop subagent: "
        + failures.map { "\($0.childID)/\($0.requestID): \($0.message)" }.joined(separator: "; ")
    case .shutDown: "The subagent scheduler is shut down"
    }
  }
}

package struct SubagentStopFailure: Equatable, Sendable {
  let childID: String
  let requestID: String
  let message: String
}
