import Foundation

public enum SubagentPreviousRoundReadiness: Equatable, Sendable {
  case ready
  /// The previous round has not finished or merged. A non-nil status is the workspace status to
  /// record as the round's `waitingReason`; nil means there is nothing new to record.
  case waiting(workspaceStatus: SubagentWorkspaceStatus?)
  /// The previous round is waiting on a merge conflict and another queued round of the same
  /// child is an explicit repair: step aside so that round can run (Node: the runner returns
  /// `false` and the repair round is picked next).
  case yielding(workspaceStatus: SubagentWorkspaceStatus)
  case failed(String)
  case inconsistent(String)
}

extension SubagentRoundPlanner {
  /// Node `waitForPreviousRound`, one pass. Only a queued continuation (`send`) has a previous
  /// round to wait for.
  public func previousRoundReadiness(of round: SubagentRound) -> SubagentPreviousRoundReadiness {
    guard round.kind == .send, round.phase == .queued else { return .ready }
    guard let previous = previousRound(of: round) else {
      return .failed("The previous subagent request is unavailable")
    }
    func ended(_ state: SubagentTaskState) -> SubagentPreviousRoundReadiness {
      .failed(
        "The previous subagent request ended with \(state.rawValue); submit a new instruction after recovery"
      )
    }
    guard let taskID = previous.taskID else {
      // Withdrawn rounds never get a task, so a recovery request cannot rescue them.
      if previous.phase == .cancelled || previous.phase == .failed {
        return ended(state(of: previous) ?? .failed)
      }
      return .waiting(workspaceStatus: nil)
    }
    let snapshot = snapshots[taskID]
    if let snapshot, snapshot.state.isFailure, !round.requestedAfterTerminal {
      return ended(snapshot.state)
    }
    if let expected = round.previousTaskID, expected != taskID {
      return .failed(
        "The previous subagent task changed before the queued instruction was dispatched")
    }
    guard let snapshot else {
      return .inconsistent(SubagentRoundRejection.snapshotUnavailable(taskID: taskID).message)
    }
    return afterTask(snapshot, of: round, ended: ended)
  }

  /// Node's `previousRequestID` lookup; without one, the nearest earlier round of the child that
  /// is not a steer.
  private func previousRound(of round: SubagentRound) -> SubagentRound? {
    if let requestID = round.previousRequestID { return self.round(round.key.childID, requestID) }
    return latest(of: round.key.childID) { $0.ordinal < round.ordinal && !$0.isSteer }
  }

  private func afterTask(
    _ snapshot: SubagentTaskSnapshot, of round: SubagentRound,
    ended: (SubagentTaskState) -> SubagentPreviousRoundReadiness
  ) -> SubagentPreviousRoundReadiness {
    let isolated = snapshot.workspaceMode == .isolated
    if snapshot.state.isFailure {
      let continuable =
        snapshot.canContinue == true && (!isolated || snapshot.workspaceStatus == .retained)
      return continuable ? .ready : ended(snapshot.state)
    }
    guard snapshot.state == .completed else { return .waiting(workspaceStatus: nil) }
    if !isolated || snapshot.workspaceStatus == .merged { return .ready }
    let status = snapshot.workspaceStatus
    if status == .conflict, round.repairConflict, snapshot.canRepairWithAgent { return .ready }
    if let status, status == .failed || status == .retained {
      return .failed(
        "The previous subagent workspace is \(status.rawValue); resolve it before continuing")
    }
    let reported = status ?? .pending
    return repairWaiting(behind: round) && reported == .conflict
      ? .yielding(workspaceStatus: reported) : .waiting(workspaceStatus: reported)
  }

  private func repairWaiting(behind round: SubagentRound) -> Bool {
    rounds.contains {
      $0.key.childID == round.key.childID && $0.key != round.key && $0.phase == .queued
        && $0.repairConflict
    }
  }
}
