import BridgeDomain
import Foundation
import GRDB

extension SimpleServiceStore {
  public func tasks(
    projectID: ProjectID? = nil, limit: Int = 100,
    search: String? = nil, providerID: String? = nil,
    status: String? = nil, offset: Int = 0
  ) throws -> [ServiceTaskRecord] {
    guard (1...500).contains(limit) else {
      throw ServiceStoreError.invalidArgument("tasks.limit")
    }
    guard offset >= 0 else { throw ServiceStoreError.invalidArgument("tasks.offset") }
    let query = search?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard query.utf8.count <= 4 * 1_024, !query.contains("\0") else {
      throw ServiceStoreError.invalidArgument("tasks.search")
    }
    if let providerID {
      try ServiceValidation.identifier(providerID, field: "tasks.providerID", maximumBytes: 64)
    }
    guard
      status == nil || status == "queued"
        || status.flatMap(ServiceTaskStatus.init(rawValue:)) != nil
    else { throw ServiceStoreError.invalidArgument("tasks.status") }
    var conditions: [String] = []
    var arguments = StatementArguments()
    if let projectID {
      conditions.append("project_id = ?")
      arguments += [projectID.rawValue]
    }
    if !query.isEmpty {
      // instr treats wildcard characters as literal text and keeps values out of SQL.
      conditions.append("instr(lower(prompt), lower(?)) > 0")
      arguments += [query]
    }
    if let providerID {
      conditions.append("provider_id = ?")
      arguments += [providerID]
    }
    if let status {
      if status == "queued" {
        conditions.append("queue_state = 'queued'")
      } else {
        conditions.append("status = ? AND queue_state = 'active'")
        arguments += [status]
      }
    }
    arguments += [limit, offset]
    let filter = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
    do {
      return try database.read { db in
        try Row.fetchAll(
          db,
          sql: """
            SELECT * FROM bridge_service_tasks
            \(filter)
            ORDER BY updated_at DESC, task_id
            LIMIT ? OFFSET ?
            """,
          arguments: arguments
        ).map(Self.decodeTask)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }
}
