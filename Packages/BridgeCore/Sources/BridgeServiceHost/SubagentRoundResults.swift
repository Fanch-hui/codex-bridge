import BridgeACP
import BridgeDomain
import BridgeServiceCore
import Foundation

struct SubagentStartRequest: Sendable {
  var rootID: String
  var childID: String
  var requestID: String
  var parentSessionID: String
  var projectID: ProjectID
  var installationID: String
  var prompt: String
  var options = SubagentRoundOptions()
  var access: SubagentRoundAccess?
  /// Children whose latest round must finish (and merge) before this one starts.
  var dependsOn: [String] = []
}

struct SubagentStartResult: Equatable, Sendable {
  /// `false`: the identical request was already queued and nothing was recorded.
  var created: Bool
}

enum SubagentSendOutcome: Equatable, Sendable {
  case replay(SubagentSendReplay)
  /// Recorded as a queued continuation; the scheduler dispatches it when the child is free.
  case queued
  /// Delivered to the running task.
  case steered(taskID: String)
}

/// A result or failure notice waiting for the controller to deliver and acknowledge it, with
/// what the controller needs to place it: the session it is delivered into and how the child is
/// shown in that session's catalog.
struct SubagentPendingResult: Equatable, Sendable {
  let key: SubagentRoundKey
  /// Nil for a round that failed before it got a task.
  let taskID: String?
  let result: SubagentTaskResult
  let parentSessionID: String
  /// `start` for the round the engine delivers itself when it still waits for it.
  let kind: SubagentRoundKind
  let label: String?
  /// `user` for work the user handed over directly: the engine writes the result down without
  /// starting a model turn.
  let origin: SubagentRoundOrigin
  let childCreatedAt: Date
}

struct SubagentPendingBatch: Equatable, Sendable {
  struct Skipped: Equatable, Sendable {
    let key: SubagentRoundKey
    let message: String
  }

  var results: [SubagentPendingResult] = []
  var skipped: [Skipped] = []
  /// The root is stopped: nothing is delivered until it runs again, except the rounds the engine
  /// asked for by name (it delivers those itself and must hear about them to finish stopping).
  var stopped = false
  /// Some round of the root is not finished (see `SubagentRoundRetention.isFinished`).
  var hasUnfinished = false
}

/// The latest round of one child, as the page and the controller list it.
struct SubagentChildSummary: Equatable, Sendable {
  let childID: String
  let installationID: String
  let requestID: String
  let phase: SubagentRoundPhase
  let taskID: String?
  /// The task state, or a state derived from the round when there is no task snapshot.
  let state: String
  let workspaceMode: SubagentWorkspaceMode?
  let workspaceStatus: String?
  let access: SubagentRoundAccess?
  let label: String?
  let model: String?
  /// Who started the child: that of its first round, which later rounds do not change.
  let origin: SubagentRoundOrigin
  let childCreatedAt: Date
  /// A queued continuation or delegation waits for this reason (`capacity`, a merge status, ...).
  let waitingReason: String?
  /// Dependencies pinned to rounds that have not finished and merged yet.
  let waitingFor: [SubagentRoundDependency]
  /// Further rounds of the child that are queued behind this one.
  let queuedCount: Int
  /// The task's fields for the page; empty without a task or a snapshot.
  let snapshot: [String: ACPJSONValue]
}

struct SubagentRoundList: Equatable, Sendable {
  var rounds: [SubagentRound]
  var children: [SubagentChildSummary]
  /// Some round of the root is not finished (see `SubagentRoundRetention.isFinished`).
  var hasUnfinished: Bool
}
