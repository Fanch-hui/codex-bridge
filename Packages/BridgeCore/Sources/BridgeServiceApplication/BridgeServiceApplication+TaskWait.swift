import BridgeMCP
import Foundation

extension BridgeServiceApplication {
  public func serviceWaitTask(
    taskID: String,
    timeoutSeconds: Int,
    recentEventLimit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskWaitResult {
    try Self.checkDeadline(deadline)
    let subscription = tasks.changes.subscription()
    defer { subscription.cancel() }
    let waitUntil = ContinuousClock.now.advanced(by: .seconds(min(max(timeoutSeconds, 1), 300)))
    return try await withThrowingTaskGroup(of: MCPServiceTaskWaitResult.self) { group in
      group.addTask {
        let snapshot = try await self.serviceTask(
          taskID: taskID, recentEventLimit: recentEventLimit, deadline: deadline)
        if let result = Self.readyTaskResult(snapshot) { return result }
        for await _ in subscription.stream {
          try Task.checkCancellation()
          let updated = try await self.serviceTask(
            taskID: taskID, recentEventLimit: recentEventLimit, deadline: deadline)
          if let result = Self.readyTaskResult(updated) { return result }
        }
        throw CancellationError()
      }
      group.addTask {
        try await Task.sleep(until: waitUntil)
        let snapshot = try await self.serviceTask(
          taskID: taskID, recentEventLimit: recentEventLimit, deadline: deadline)
        return Self.readyTaskResult(snapshot)
          ?? MCPServiceTaskWaitResult(task: snapshot, waitStatus: .stillRunning)
      }
      defer { group.cancelAll() }
      guard let result = try await group.next() else { throw CancellationError() }
      return result
    }
  }

  private nonisolated static func readyTaskResult(
    _ snapshot: MCPServiceTaskSnapshot
  ) -> MCPServiceTaskWaitResult? {
    let status: MCPServiceTaskWaitStatus
    if snapshot.waitPolicy.terminal {
      status = .terminal
    } else if snapshot.pendingUserInput != nil {
      status = .needsInput
    } else if snapshot.localApprovalRequired {
      status = .awaitingApproval
    } else {
      return nil
    }
    return MCPServiceTaskWaitResult(task: snapshot, waitStatus: status)
  }
}
