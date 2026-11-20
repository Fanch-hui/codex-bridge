import Foundation

/// A result or failure notice that still has to reach the controller.
public struct SubagentPendingDelivery: Equatable, Sendable {
  public enum Outcome: Equatable, Sendable {
    /// The task finished; its output and state come from the task record.
    case task(taskID: String)
    /// The round never got a task; deliver this text as the failed result.
    case failure(notice: String)
  }

  public let key: SubagentRoundKey
  public let outcome: Outcome
  /// The round is still `running` although its task finished: move it to `settled` first.
  public let needsSettle: Bool
}

/// Texts the controller reads.
public enum SubagentRoundNotice {
  /// Sent when a dispatch ended without a definite outcome (not a final result; nothing is
  /// acknowledged).
  public static let unconfirmed = "The subagent delivery outcome is being checked."
  public static let notDispatched =
    "The subagent request was not dispatched; delegate again if still needed."

  public static func rejectedByBridge(_ reason: String) -> String {
    "Bridge rejected the subagent request: \(reason)"
  }

  /// The failed result delivered for a round that has no task (Node `deliver` with state
  /// `failed`).
  public static func failure(of round: SubagentRound) -> String {
    switch round.failureOrigin {
    case .dispatch:
      return round.failureReason.map(rejectedByBridge) ?? notDispatched
    case .dependency, .input, nil:
      return round.failureReason ?? ""
    }
  }
}

extension SubagentRoundPlanner {
  /// The results that have to be delivered, oldest first: finished tasks (Node `results` loop,
  /// skipping children a live runner will deliver itself) and rounds that failed before they got
  /// a task. A steer and a withdrawn round never deliver anything.
  public func pendingDeliveries(liveChildren: Set<String> = []) -> [SubagentPendingDelivery] {
    rounds.compactMap { round in
      guard round.deliveryRequired, !round.delivered else { return nil }
      switch round.phase {
      case .failed:
        return SubagentPendingDelivery(
          key: round.key, outcome: .failure(notice: SubagentRoundNotice.failure(of: round)),
          needsSettle: false)
      case .settled, .running:
        guard let taskID = round.taskID, !liveChildren.contains(round.key.childID),
          isTerminal(round)
        else { return nil }
        return SubagentPendingDelivery(
          key: round.key, outcome: .task(taskID: taskID), needsSettle: round.phase == .running)
      default:
        return nil
      }
    }
  }
}
