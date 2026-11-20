import Foundation

/// What a probe by request ID found (Node: the `probe` answer of Bridge).
public struct SubagentProbe: Equatable, Sendable {
  public enum State: Equatable, Sendable {
    case absent, active, terminal, unknown, deliveryUnknown
  }

  public var state: State
  public var workspaceMode: SubagentWorkspaceMode?
  public var taskID: String?

  public init(
    state: State, workspaceMode: SubagentWorkspaceMode? = nil, taskID: String? = nil
  ) {
    self.state = state
    self.workspaceMode = workspaceMode
    self.taskID = taskID
  }
}

/// What to do with a task found for a round while its root is stopped.
public enum SubagentStoppedTaskAction: Equatable, Sendable {
  /// The task still runs: tell it to stop.
  case stopTask
  /// The task already finished: record it as `interrupted`.
  case settleInterrupted
}

public enum SubagentReconciliation: Equatable, Sendable {
  case none
  /// A queued round: make sure the scheduler considers it.
  case requeue
  /// A steer whose delivery cannot be established. Never resent.
  case markDeliveryUnknown(taskID: String?)
  /// The request never reached Bridge. Fail the round (`failureOrigin == .dispatch`, reason =
  /// the stored `dispatchError`) and deliver the notice.
  case failNotDispatched(reason: String?)
  /// The task exists. If `adopt`, the round was unconfirmed: read the task, store its ID and
  /// move to `running` (`attached` for a steer). `whileStopped` is set when the root is stopped.
  case taskFound(adopt: Bool, whileStopped: SubagentStoppedTaskAction?)
  /// Node threw `Invalid recovered task identity`.
  case inconsistent(String)
}

extension SubagentRoundPlanner {
  /// Node `reconcile`, for one round. `probe` is the answer for a round that holds a reservation,
  /// a lease or an unconfirmed dispatch (nil when nothing was probed); `isSending` is true while
  /// a live send of the request is being persisted and `isLive` while a live runner owns the round. Releasing reservations and leases according to the
  /// probe stays with the scheduler.
  public func reconcile(
    _ round: SubagentRound, probe: SubagentProbe?, rootStopped: Bool, isSending: Bool = false,
    isLive: Bool = false
  ) -> SubagentReconciliation {
    if isSending || round.phase == .deliveryUnknown { return .none }
    if round.phase == .queued { return .requeue }
    if isLive && round.phase != .unknown { return .none }
    guard let probe else { return .none }
    switch probe.state {
    case .deliveryUnknown where round.isSteer:
      if let known = round.taskID, let found = probe.taskID, known != found {
        return .inconsistent("Invalid recovered task identity")
      }
      return .markDeliveryUnknown(taskID: probe.taskID)
    case .absent where round.phase.isUnconfirmed:
      return .failNotDispatched(reason: round.dispatchError)
    case .active, .terminal:
      var stopped: SubagentStoppedTaskAction?
      if rootStopped { stopped = probe.state == .active ? .stopTask : .settleInterrupted }
      return .taskFound(adopt: round.phase.isUnconfirmed, whileStopped: stopped)
    default:
      return .none
    }
  }
}
