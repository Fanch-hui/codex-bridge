import BridgeDomain
import BridgeMCP
import Foundation

extension BridgeServiceApplication {
  private struct TaskCursor: Codable {
    let projectID: String?
    let updatedAt: Date
    let taskID: String
  }

  public func serviceListTasks(
    projectID: String?, cursor: String?, limit: Int, deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskListPage {
    try Self.checkDeadline(deadline)
    guard (1...100).contains(limit) else { throw BridgeMCPQueryError.contractRejected }
    if let projectID { _ = try await readableProject(projectID) }
    var position: TaskCursor?
    if let cursor {
      guard let data = Data(base64Encoded: cursor),
        let decoded = try? JSONDecoder().decode(TaskCursor.self, from: data),
        decoded.projectID == projectID
      else { throw BridgeMCPQueryError.contractRejected }
      position = decoded
    }
    let records = try await tasks.taskPage(
      projectID: projectID.map(ProjectID.init(rawValue:)), beforeDate: position?.updatedAt,
      beforeID: position?.taskID, limit: limit + 1)
    let visible = records.prefix(limit)
    let readableIDs = Set(
      try await projects.projects().filter { $0.accessPolicy.read == .allowed }.map {
        $0.id.rawValue
      })
    var items: [MCPTaskListItem] = []
    for task in visible where readableIDs.contains(task.projectID.rawValue) {
      let queueInfo = try await tasks.queueInfo(taskID: task.id)
      items.append(
        MCPTaskListItem(
          taskID: task.id.rawValue, projectID: task.projectID.rawValue, providerID: task.providerID,
          status: task.isQueued ? "queued" : task.state.status.rawValue,
          prompt: Self.safe(task.prompt, maximum: 512),
          updatedAt: iso8601.string(from: task.updatedAt),
          queuePosition: queueInfo?.position,
          queueOccupantTaskID: queueInfo?.occupyingTaskID?.rawValue,
          queueRequestedAt: queueInfo.map { iso8601.string(from: $0.enqueuedAt) }
        )
      )
    }
    let next: String?
    if records.count > limit, let last = visible.last {
      next = try JSONEncoder().encode(
        TaskCursor(projectID: projectID, updatedAt: last.updatedAt, taskID: last.id.rawValue)
      ).base64EncodedString()
    } else {
      next = nil
    }
    return MCPTaskListPage(tasks: items, nextCursor: next)
  }
}
