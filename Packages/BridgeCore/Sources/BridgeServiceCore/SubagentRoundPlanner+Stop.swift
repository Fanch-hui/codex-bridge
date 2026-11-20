import Foundation

/// What `stop(child)` has to do. The scheduler applies it in this order.
public struct SubagentStopPlan: Equatable, Sendable {
  /// Queued rounds of the child to cancel (all of them except the one a live runner owns).
  public var cancelQueued: [SubagentRoundKey]
  /// A live runner owns this round and it has no task yet: abort the runner and wait for it.
  public var abortLiveRound: SubagentRoundKey?
  /// After the aborted runner finished, a round still `unknown` means the stop cannot be
  /// confirmed: fail with `SubagentRoundRejection.outcomeStillBeingChecked`.
  public var failsIfOutcomeStaysUnknown: Bool
  /// The round whose task must be told to stop.
  public var stopRound: SubagentRoundKey?
}

public enum SubagentCancelInputState: String, Equatable, Sendable {
  case notFound, unknown, settled, cancelled, stopping
}

/// What `cancelInput(request)` has to do, and the status to answer with.
public struct SubagentCancelInputPlan: Equatable, Sendable {
  public var state: SubagentCancelInputState
  public var cancelQueued: SubagentRoundKey?
  /// Abort the live runner that owns this round.
  public var abortLiveRound: Bool
  public var stopRound: SubagentRoundKey?
}

/// What `stopRoot` has to do for every child of the root.
public struct SubagentStopRootPlan: Equatable, Sendable {
  /// Queued rounds no live runner owns.
  public var cancelQueued: [SubagentRoundKey]
  /// Rounds owned by live runners: abort them.
  public var abortLiveRounds: [SubagentRoundKey]
  /// Rounds whose task must be told to stop: live rounds with a task, then rounds nobody owns
  /// (recovered after a restart) that may still be running or unconfirmed.
  public var stopRounds: [SubagentRoundKey]
}

extension SubagentRoundPlanner {
  /// Node `stop`. `liveRequestIDs` maps a child to the request ID of the round its live runner
  /// owns (Node `starting`).
  public func planStop(
    childID: String, expectedTaskID: String? = nil, expectedRunID: String? = nil,
    liveRequestIDs: [String: String] = [:]
  ) throws -> SubagentStopPlan {
    try assertCurrent(
      childID: childID, expectedTaskID: expectedTaskID, expectedRunID: expectedRunID)
    let own = rounds(of: childID).filter { !$0.isSteer }
    let live = liveRequestIDs[childID].flatMap { round(childID, $0) }
    let candidate =
      live
      ?? own.last { [.dispatching, .unknown, .running].contains($0.phase) && !isTerminal($0) }
      ?? own.last
    guard let candidate else { throw SubagentRoundRejection.childNotFound }
    let cancelQueued = rounds(of: childID).filter {
      $0.phase == .queued && $0.key != live?.key
    }.map(\.key)
    var plan = SubagentStopPlan(
      cancelQueued: cancelQueued, abortLiveRound: nil, failsIfOutcomeStaysUnknown: false,
      stopRound: nil)
    if let live, live.taskID == nil {
      plan.abortLiveRound = live.key
      plan.failsIfOutcomeStaysUnknown = live.phase != .queued && live.phase != .cancelled
    } else if let live {
      plan.stopRound = live.key
    } else if candidate.taskID != nil || candidate.phase.isUnconfirmed, !isTerminal(candidate) {
      plan.stopRound = candidate.key
    }
    return plan
  }

  /// Node `cancelInput`: withdraws one recorded request.
  public func planCancelInput(
    childID: String, requestID: String, isSending: Bool = false,
    liveRequestIDs: [String: String] = [:]
  ) -> SubagentCancelInputPlan {
    func answer(
      _ state: SubagentCancelInputState, queued: SubagentRoundKey? = nil,
      abort: Bool = false, stop: SubagentRoundKey? = nil
    ) -> SubagentCancelInputPlan {
      SubagentCancelInputPlan(
        state: state, cancelQueued: queued, abortLiveRound: abort, stopRound: stop)
    }
    guard let target = round(childID, requestID) else {
      return answer(isSending ? .unknown : .notFound)
    }
    let owned = liveRequestIDs[childID] == requestID
    // Node reports a steer in `delivery_unknown` as settled; only `dispatching` / `unknown` are
    // unknown.
    if target.isSteer { return answer(target.phase.isUnconfirmed ? .unknown : .settled) }
    if target.phase == .queued { return answer(.cancelled, queued: target.key, abort: owned) }
    if target.phase == .cancelled || target.phase == .failed || isTerminal(target) {
      return answer(.settled)
    }
    if owned && target.taskID == nil { return answer(.unknown, abort: true) }
    guard let taskID = target.taskID, currentRun(of: childID)?.taskID == taskID else {
      return answer(.unknown)
    }
    return answer(.stopping, stop: target.key)
  }

  /// Node `stopRoot`.
  public func planStopRoot(liveRequestIDs: [String: String] = [:]) -> SubagentStopRootPlan {
    let live = rounds.filter { liveRequestIDs[$0.key.childID] == $0.key.requestID }
    let liveKeys = Set(live.map(\.key))
    let recovered = rounds.filter {
      !$0.isSteer && !liveKeys.contains($0.key) && !isTerminal($0)
        && [.running, .dispatching, .unknown].contains($0.phase)
    }
    return SubagentStopRootPlan(
      cancelQueued: rounds.filter { $0.phase == .queued && !liveKeys.contains($0.key) }
        .map(\.key),
      abortLiveRounds: live.map(\.key),
      stopRounds: (live.filter { $0.taskID != nil } + recovered).map(\.key))
  }

  /// Node `hasRunning`: the root has a live runner, or a round that is running or unconfirmed.
  /// An unconfirmed steer counts; a steer that was attached does not.
  public func hasRunning(liveRequestIDs: [String: String] = [:]) -> Bool {
    rounds.contains { liveRequestIDs[$0.key.childID] == $0.key.requestID }
      || rounds.contains {
        [.running, .dispatching, .unknown].contains($0.phase) && !isTerminal($0)
      }
  }
}
