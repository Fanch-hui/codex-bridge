import Foundation

public struct SubagentPendingDependency: Equatable, Sendable {
  public let childID: String
  public let state: SubagentTaskState
  public let workspaceStatus: SubagentWorkspaceStatus?

  public init(
    childID: String, state: SubagentTaskState, workspaceStatus: SubagentWorkspaceStatus? = nil
  ) {
    self.childID = childID
    self.state = state
    self.workspaceStatus = workspaceStatus
  }
}

public enum SubagentDependencyReadiness: Equatable, Sendable {
  case ready
  /// Some dependencies have not finished or merged yet; check again later.
  case waiting([SubagentPendingDependency])
  /// A dependency can no longer succeed (Node `AgentDependencyError`): fail the dependent round.
  case failed(String)
  /// The check could not be completed (Node: a plain `Error`): keep the round queued and retry.
  case inconsistent(String)
}

extension SubagentRoundPlanner {
  /// Node `dependenciesFor`: pins each named child to its latest round that is not an attached
  /// steer. Duplicates collapse to the first mention.
  public func resolveDependencies(childIDs: [String]) throws -> [SubagentRoundDependency] {
    var seen = Set<String>()
    return try childIDs.filter { seen.insert($0).inserted }.map { childID in
      guard let target = latest(of: childID, where: { $0.phase != .attached }) else {
        throw SubagentRoundRejection.dependencyNotConnected(childID: childID)
      }
      return SubagentRoundDependency(childID: childID, requestID: target.key.requestID)
    }
  }

  /// Node `waitForDependencies`, one pass. Dependencies are examined in order and the first
  /// failure or inconsistency wins over pending ones seen earlier.
  public func dependencyReadiness(of dependencies: [SubagentRoundDependency])
    -> SubagentDependencyReadiness
  {
    var pending: [SubagentPendingDependency] = []
    for dependency in dependencies {
      switch check(dependency) {
      case .ready: continue
      case .waiting(let entry): pending.append(contentsOf: entry)
      case let other: return other
      }
    }
    return pending.isEmpty ? .ready : .waiting(pending)
  }

  private func check(_ dependency: SubagentRoundDependency) -> SubagentDependencyReadiness {
    let childID = dependency.childID
    guard let target = round(childID, dependency.requestID) else {
      return .inconsistent("Dependency \(childID) is unavailable")
    }
    func ended(_ state: SubagentTaskState) -> SubagentDependencyReadiness {
      .failed(
        "Dependency \(childID) ended with \(state.rawValue); delegate the dependent task again after recovery"
      )
    }
    if target.phase == .cancelled || target.phase == .failed {
      return ended(state(of: target) ?? .failed)
    }
    guard let taskID = target.taskID else {
      return .waiting([SubagentPendingDependency(childID: childID, state: .created)])
    }
    guard let snapshot = snapshots[taskID] else {
      return .inconsistent(SubagentRoundRejection.snapshotUnavailable(taskID: taskID).message)
    }
    if snapshot.state.isFailure { return ended(snapshot.state) }
    if let status = snapshot.workspaceStatus, status == .failed || status == .retained {
      return .failed(
        "Dependency \(childID) has workspace status \(status.rawValue); resolve it before delegating again"
      )
    }
    let merged = snapshot.workspaceMode != .isolated || snapshot.workspaceStatus == .merged
    guard snapshot.state == .completed, merged else {
      return .waiting([
        SubagentPendingDependency(
          childID: childID, state: snapshot.state, workspaceStatus: snapshot.workspaceStatus)
      ])
    }
    return .ready
  }
}
