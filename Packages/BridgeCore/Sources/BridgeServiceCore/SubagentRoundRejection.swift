import Foundation

/// A request the planner refuses. The messages are the ones the Node orchestrator produced; the
/// controlling model reads them, so they are kept word for word.
public enum SubagentRoundRejection: Error, Equatable, Sendable {
  case childNotFound
  /// The child belongs to another root. The planner only sees one root's rounds, so the caller
  /// raises this after looking the child up elsewhere.
  case wrongRoot
  case unsupportedDelivery
  case invalidOptions
  case repairRequiresQueue
  case instructionConflict
  case movedToDifferentRun
  case notRunning
  case attachmentsWhileRunning
  case cannotSteer
  case cannotContinue
  case alreadyAdmitted
  case alreadyQueued
  case outcomeStillBeingChecked
  case dependencyNotConnected(childID: String)
  /// A decision needs the snapshot of this task and the caller did not supply one (Node: the
  /// `get` request failed). Retry once the snapshot can be read.
  case snapshotUnavailable(taskID: String)

  public var message: String {
    switch self {
    case .childNotFound: "Bridge subagent not found"
    case .wrongRoot: "Subagent belongs to another session"
    case .unsupportedDelivery: "Unsupported subagent delivery mode"
    case .invalidOptions: "Invalid subagent attachment or repair options"
    case .repairRequiresQueue: "Workspace repair requires a queued continuation"
    case .instructionConflict: "Request ID is already bound to another instruction"
    case .movedToDifferentRun: "The subagent has moved to a different task or run"
    case .notRunning: "The subagent is not running"
    case .attachmentsWhileRunning:
      "Running subagents cannot receive attachments; queue a continuation instead"
    case .cannotSteer:
      "This subagent cannot receive a running instruction; queue a continuation instead"
    case .cannotContinue: "This subagent cannot continue from its current state"
    case .alreadyAdmitted: "Subagent request was already admitted"
    case .alreadyQueued: "Subagent request is already queued"
    case .outcomeStillBeingChecked: "The subagent outcome is still being checked"
    case .dependencyNotConnected(let childID):
      "Dependency \(childID) is not a connected subagent in this session"
    case .snapshotUnavailable(let taskID): "The snapshot of subagent task \(taskID) is unavailable"
    }
  }
}
