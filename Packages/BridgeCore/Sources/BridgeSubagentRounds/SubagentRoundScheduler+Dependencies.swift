import BridgeServiceCore
import Foundation

extension SubagentRoundScheduler {
  /// Whether the named children have finished and merged, for work the scheduler does not run
  /// itself (the controlling adapter's native subagents wait for connected children this way). It reads the
  /// ledger and the tasks' snapshots and changes nothing; an unknown child is refused.
  package func dependencyReadiness(
    rootID: String, childIDs: [String], pinned: [SubagentRoundDependency]? = nil
  ) async throws -> (
    readiness: SubagentDependencyReadiness, dependencies: [SubagentRoundDependency]
  ) {
    try await withLane(rootID) {
      let rounds = try await ledger.rounds(rootID: rootID)
      let first = SubagentRoundPlanner(rootID: rootID, rounds: rounds)
      let dependencies = try pinned ?? first.resolveDependencies(childIDs: childIDs)
      let targets = rounds.filter { round in
        dependencies.contains {
          $0.childID == round.key.childID && $0.requestID == round.key.requestID
        }
      }
      let snapshots = await readSnapshots(rootID: rootID, rounds: targets)
      let readiness = SubagentRoundPlanner(rootID: rootID, rounds: rounds, snapshots: snapshots)
        .dependencyReadiness(of: dependencies)
      return (readiness, dependencies)
    }
  }
}
