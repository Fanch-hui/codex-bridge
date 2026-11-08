import BridgeDomain

extension ServiceExecutionCoordinator {
  public func canSteerSubagent(taskID: TaskID, runID: String) -> Bool {
    guard !finishedRuns.contains(taskID) else { return false }
    if let run = activeAgentRuns[taskID] {
      return run.effectiveRunID == runID && run.steer != nil
    }
    return collectors[taskID] != nil
  }
}
