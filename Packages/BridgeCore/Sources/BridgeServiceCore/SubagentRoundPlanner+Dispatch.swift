import Foundation

/// Whether a queued round may go on to admission (reservation, lease, dispatch).
public enum SubagentRoundReadiness: Equatable, Sendable {
  case ready
  case waitingForDependencies([SubagentPendingDependency])
  case waitingForPreviousRound(workspaceStatus: SubagentWorkspaceStatus?)
  case yielding(workspaceStatus: SubagentWorkspaceStatus)
  /// Fail the round with this reason (`failureOrigin == .dependency`) and notify the controller.
  case failed(String)
  /// Keep the round queued and try again later.
  case inconsistent(String)
}

extension SubagentRoundPlanner {
  /// Node `resumeNext`: the queued round of `childID` that may start now, if any.
  ///
  /// Nothing starts while the child has a live runner (`busyChildren`), an unconfirmed dispatch, a
  /// running task, or a finished task whose result was not delivered yet. Among the queued rounds
  /// the oldest goes first, except that once one of them waits on a merge conflict an explicit
  /// repair round is preferred.
  public func nextDispatchable(childID: String, busyChildren: Set<String> = []) -> SubagentRound? {
    guard !busyChildren.contains(childID) else { return nil }
    let own = rounds(of: childID).filter { !$0.isSteer }
    guard !own.contains(where: blocksNextRound) else { return nil }
    let queued = own.filter { $0.phase == .queued }
    guard queued.contains(where: { $0.waitingReason == SubagentWorkspaceStatus.conflict.rawValue })
    else { return queued.first }
    return queued.first { $0.repairConflict } ?? queued.first
  }

  /// `nextDispatchable` for every child that has a queued round, in queue order.
  public func dispatchCandidates(busyChildren: Set<String> = []) -> [SubagentRound] {
    var seen = Set<String>()
    return rounds.filter { $0.phase == .queued && seen.insert($0.key.childID).inserted }
      .compactMap { nextDispatchable(childID: $0.key.childID, busyChildren: busyChildren) }
  }

  /// The two blocking conditions of `resumeNext`.
  private func blocksNextRound(_ round: SubagentRound) -> Bool {
    switch round.phase {
    case .dispatching, .unknown: return true
    case .running: return !isTerminal(round) || (round.deliveryRequired && !round.delivered)
    case .settled: return round.deliveryRequired && !round.delivered
    default: return false
    }
  }

  /// The waits of Node `runQueued` before admission: dependencies first, then the previous round.
  public func readiness(of round: SubagentRound) -> SubagentRoundReadiness {
    switch dependencyReadiness(of: round.dependencies) {
    case .ready: break
    case .waiting(let pending): return .waitingForDependencies(pending)
    case .failed(let reason): return .failed(reason)
    case .inconsistent(let message): return .inconsistent(message)
    }
    switch previousRoundReadiness(of: round) {
    case .ready: return .ready
    case .waiting(let status): return .waitingForPreviousRound(workspaceStatus: status)
    case .yielding(let status): return .yielding(workspaceStatus: status)
    case .failed(let reason): return .failed(reason)
    case .inconsistent(let message): return .inconsistent(message)
    }
  }
}
