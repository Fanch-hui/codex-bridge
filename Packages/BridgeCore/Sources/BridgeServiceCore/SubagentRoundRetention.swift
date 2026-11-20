import Foundation

/// Conservative cleanup of finished rounds (Node `agent-retention.mjs`).
///
/// A round stays addressable by request ID for idempotent retries and by child ID for follow-ups,
/// so only superseded rounds that have been finished and delivered for a long time are dropped.
/// Anything uncertain is kept.
public enum SubagentRoundRetention {
  public static let window: TimeInterval = 7 * 24 * 60 * 60

  public struct Plan: Equatable, Sendable {
    /// Newly finished rounds: start their retention window now.
    public var stamp: [SubagentRoundKey] = []
    /// Rounds that were stamped but are not finished (any more): drop the stamp.
    public var clear: [SubagentRoundKey] = []
    public var remove: [SubagentRoundKey] = []
    public var isEmpty: Bool { stamp.isEmpty && clear.isEmpty && remove.isEmpty }
  }

  /// Nothing is left to dispatch, wait for, release or deliver for this round.
  ///
  /// Unlike Node, a round that failed before it got a task is only finished once its failure
  /// notice was delivered, and a held lease keeps a round open as a held reservation does.
  public static func isFinished(_ round: SubagentRound) -> Bool {
    if round.reservationHeld || round.leaseHeld { return false }
    switch round.phase {
    case .queued, .dispatching, .unknown, .deliveryUnknown, .running: return false
    case .attached, .cancelled: return true
    case .failed, .settled: return !round.deliveryRequired || round.delivered
    }
  }

  /// Stamps and clears settle times and picks the rounds to remove. `rounds` are the rounds of
  /// one root, oldest first; `isBusy` marks rounds a live runner or call still uses.
  public static func plan(
    rounds: [SubagentRound], now: Date, isBusy: (SubagentRound) -> Bool = { _ in false }
  ) -> Plan {
    var plan = Plan()
    var settled: [SubagentRoundKey: Date] = [:]
    for round in rounds {
      if !isFinished(round) {
        if round.settledAt != nil { plan.clear.append(round.key) }
      } else if let stamp = round.settledAt {
        settled[round.key] = stamp
      } else {
        // A round without a stamp starts its window when it is first seen finished.
        plan.stamp.append(round.key)
        settled[round.key] = now
      }
    }
    let protected = protectedKeys(rounds)
    plan.remove = rounds.filter { round in
      guard !protected.contains(round.key), !isBusy(round), let stamp = settled[round.key] else {
        return false
      }
      return now.timeIntervalSince(stamp) >= window
    }.map(\.key)
    return plan
  }

  /// Rounds that later lookups still resolve to: the latest ones of each child and everything an
  /// unfinished round depends on or follows.
  static func protectedKeys(_ rounds: [SubagentRound]) -> Set<SubagentRoundKey> {
    var keep = Set<SubagentRoundKey>()
    let byChild = Dictionary(grouping: rounds, by: { $0.key.childID })
    for childRounds in byChild.values {
      if let first = childRounds.first, first.kind == .start, first.options.origin == .user {
        keep.insert(first.key)
      }
      let candidates = [
        childRounds.last { !$0.isSteer },
        childRounds.last { !$0.isSteer && $0.taskID != nil },
        childRounds.last { $0.phase != .attached },
        childRounds.last,
      ]
      for candidate in candidates.compactMap({ $0 }) { keep.insert(candidate.key) }
    }
    for round in rounds where !isFinished(round) {
      for dependency in round.dependencies {
        if let target = rounds.first(where: {
          $0.key.childID == dependency.childID && $0.key.requestID == dependency.requestID
        }) {
          keep.insert(target.key)
        }
      }
      let queuedSend = round.kind == .send && round.prompt != nil
      guard queuedSend || round.previousRequestID != nil else { continue }
      let siblings = byChild[round.key.childID] ?? []
      let previous: SubagentRound?
      if let requestID = round.previousRequestID {
        previous = siblings.first { $0.key.requestID == requestID }
      } else {
        previous = siblings.last { $0.ordinal < round.ordinal && !$0.isSteer }
      }
      if let previous { keep.insert(previous.key) }
    }
    return keep
  }
}
