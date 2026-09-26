import BridgeAgentCore
import BridgeDomain
import Foundation
import GRDB

extension SimpleServiceStore {
  public func setTaskUsage(_ usage: AgentUsageStatistics, taskID: TaskID) throws {
    let data = try JSONEncoder().encode(usage)
    try database.write { db in
      try db.execute(
        sql: """
          INSERT INTO bridge_service_task_usage(task_id, snapshot) VALUES (?, ?)
          ON CONFLICT(task_id) DO UPDATE SET snapshot = excluded.snapshot
          """,
        arguments: [taskID.rawValue, data]
      )
    }
  }

  public func taskUsage(taskID: TaskID) throws -> AgentUsageStatistics? {
    try taskUsage(taskIDs: [taskID])[taskID]
  }

  public func taskUsage(taskIDs: [TaskID]) throws -> [TaskID: AgentUsageStatistics] {
    guard !taskIDs.isEmpty else { return [:] }
    let slots = Array(repeating: "?", count: taskIDs.count).joined(separator: ",")
    return try database.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: "SELECT task_id, snapshot FROM bridge_service_task_usage WHERE task_id IN (\(slots))",
        arguments: StatementArguments(taskIDs.map(\.rawValue))
      )
      return try Dictionary(
        uniqueKeysWithValues: rows.map { row in
          let id: String = row["task_id"]
          let data: Data = row["snapshot"]
          return (
            TaskID(rawValue: id), try JSONDecoder().decode(AgentUsageStatistics.self, from: data)
          )
        })
    }
  }
}

extension ServiceTaskManager {
  public func recordUsage(_ usage: AgentUsageStatistics, taskID: TaskID) async throws {
    try await store.setTaskUsage(usage, taskID: taskID)
    changes.publish()
  }

  public func usage(taskID: TaskID) async throws -> AgentUsageStatistics? {
    try await store.taskUsage(taskID: taskID)
  }

  public func usage(taskIDs: [TaskID]) async throws -> [TaskID: AgentUsageStatistics] {
    try await store.taskUsage(taskIDs: taskIDs)
  }
}
