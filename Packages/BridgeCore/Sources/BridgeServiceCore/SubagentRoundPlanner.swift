import Foundation

/// Pure scheduling rules for the rounds of one root: no I/O, no clock, no actor. Every decision
/// is a function of the rounds and of the task snapshots the caller read just before asking.
///
/// This is a faithful port of the Node orchestrator (`bridge-agents.mjs`, `agent-inputs.mjs`,
/// `agent-handoff.mjs`, `agent-retention.mjs`). Where Node read `binding.state` it now reads the
/// task snapshot (`state(of:)`); where Node issued a `get` request it now needs the snapshot to be
/// in `snapshots`, otherwise the decision fails with `snapshotUnavailable` or reports
/// `inconsistent`.
public struct SubagentRoundPlanner: Sendable {
  public let rootID: String
  /// The rounds of `rootID`, oldest first.
  public let rounds: [SubagentRound]
  let snapshots: [String: SubagentTaskSnapshot]

  public init(rootID: String, rounds: [SubagentRound], snapshots: [SubagentTaskSnapshot] = []) {
    self.rootID = rootID
    self.rounds = rounds.filter { $0.key.rootID == rootID }.sorted { $0.ordinal < $1.ordinal }
    self.snapshots = Dictionary(snapshots.map { ($0.taskID, $0) }) { _, latest in latest }
  }

  // MARK: - Lookups

  func round(_ childID: String, _ requestID: String) -> SubagentRound? {
    rounds.first { $0.key.childID == childID && $0.key.requestID == requestID }
  }

  func rounds(of childID: String) -> [SubagentRound] {
    rounds.filter { $0.key.childID == childID }
  }

  func latest(of childID: String, where predicate: (SubagentRound) -> Bool = { _ in true })
    -> SubagentRound?
  {
    rounds.last { $0.key.childID == childID && predicate($0) }
  }

  /// The snapshot the caller supplied for the round's task, if any.
  public func snapshot(of round: SubagentRound) -> SubagentTaskSnapshot? {
    round.taskID.flatMap { snapshots[$0] }
  }

  /// Node `binding.state`: `cancelled` / `failed` for withdrawn rounds, `created` before a task
  /// exists, otherwise the task's state; `nil` when the task's snapshot is missing.
  public func state(of round: SubagentRound) -> SubagentTaskState? {
    switch round.phase {
    case .cancelled: return .cancelled
    case .failed: return .failed
    default:
      guard round.taskID != nil else { return .created }
      return snapshot(of: round)?.state
    }
  }

  /// Node `terminal.has(binding.state)`.
  public func isTerminal(_ round: SubagentRound) -> Bool {
    state(of: round)?.isTerminal ?? (round.phase == .settled)
  }

  /// Node `currentRun`: the latest round of the child that has a task and is not a steer.
  func currentRun(of childID: String) -> SubagentRound? {
    latest(of: childID) { $0.taskID != nil && !$0.isSteer }
  }

  /// The round whose task is running right now (Node `active`).
  func activeRun(of childID: String) -> SubagentRound? {
    latest(of: childID) { $0.phase == .running && !$0.isSteer && !isTerminal($0) }
  }

  /// Node `assertCurrent`: a control that names a task or run is only valid for the current one.
  func assertCurrent(childID: String, expectedTaskID: String?, expectedRunID: String?) throws {
    guard expectedTaskID != nil || expectedRunID != nil else { return }
    guard let current = currentRun(of: childID),
      expectedTaskID == nil || current.taskID == expectedTaskID,
      expectedRunID == nil || snapshot(of: current)?.runID == expectedRunID
    else { throw SubagentRoundRejection.movedToDifferentRun }
  }
}
