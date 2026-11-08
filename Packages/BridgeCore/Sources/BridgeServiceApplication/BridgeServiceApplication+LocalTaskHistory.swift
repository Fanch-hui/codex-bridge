import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public func serviceLocalTaskHistory(
    taskID: String, recentEventLimit: Int, deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskSnapshot {
    try Self.checkDeadline(deadline)
    let id = TaskID(rawValue: taskID)
    guard let task = try await tasks.task(id: id) else { throw BridgeMCPQueryError.taskNotFound }
    guard try await projects.project(id: task.projectID) != nil else {
      throw BridgeMCPQueryError.projectNotFound
    }
    let events = try await tasks.events(taskID: id, limit: min(max(recentEventLimit, 1), 6))
    let messages = try await tasks.recentMessageActivity(
      taskID: id, limit: min(max(recentEventLimit, 1), 8))
    let attachments = try await tasks.taskAttachments(taskID: id)
    return taskSnapshot(
      task: task, events: events, activityMessages: messages, recentActivityAvailable: true,
      queueInfo: try await tasks.queueInfo(taskID: id),
      attachmentPaths: attachments.map(\.relativePath), usage: try await tasks.usage(taskID: id),
      canOpenNativeSession: false)
  }
}
