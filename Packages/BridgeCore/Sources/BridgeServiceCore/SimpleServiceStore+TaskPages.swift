import BridgeDomain
import Foundation
import GRDB

extension SimpleServiceStore {
  public func taskPage(projectID: ProjectID?, beforeDate: Date?, beforeID: String?, limit: Int)
    throws -> [ServiceTaskRecord]
  {
    guard (1...101).contains(limit) else { throw ServiceStoreError.invalidArgument("tasks.limit") }
    return try database.read { db in
      var conditions: [String] = []
      var arguments = StatementArguments()
      if let projectID {
        conditions.append("project_id = ?")
        arguments += [projectID.rawValue]
      }
      if let beforeDate, let beforeID {
        conditions.append("(updated_at < ? OR (updated_at = ? AND task_id > ?))")
        arguments += [beforeDate.timeIntervalSince1970, beforeDate.timeIntervalSince1970, beforeID]
      }
      let predicate = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
      arguments += [limit]
      return try Row.fetchAll(
        db,
        sql:
          "SELECT * FROM bridge_service_tasks \(predicate) ORDER BY updated_at DESC, task_id LIMIT ?",
        arguments: arguments
      ).map(Self.decodeTask)
    }
  }
}

extension ServiceTaskManager {
  public func taskPage(projectID: ProjectID?, beforeDate: Date?, beforeID: String?, limit: Int)
    async throws -> [ServiceTaskRecord]
  {
    try await store.taskPage(
      projectID: projectID, beforeDate: beforeDate, beforeID: beforeID, limit: limit)
  }
}
