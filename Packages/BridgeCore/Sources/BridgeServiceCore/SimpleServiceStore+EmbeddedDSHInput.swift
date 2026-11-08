import BridgeDomain
import GRDB

public struct EmbeddedDSHInputState: Sendable, Equatable {
  public let taskID: TaskID?
  public let status: ServiceTaskStatus?
}

extension SimpleServiceStore {
  public func embeddedDSHInput(
    parentSessionID: String, childID: String, requestID: String
  ) throws -> EmbeddedDSHInputState? {
    try ServiceValidation.identifier(
      parentSessionID, field: "dsh.parentSessionID", maximumBytes: 1_024)
    try ServiceValidation.identifier(childID, field: "dsh.childID", maximumBytes: 1_024)
    try ServiceValidation.identifier(requestID, field: "dsh.requestID", maximumBytes: 1_024)
    do {
      return try database.read { db in
        guard
          let row = try Row.fetchOne(
            db,
            sql: """
              SELECT i.task_id, t.status
              FROM bridge_service_embedded_dsh_inputs i
              LEFT JOIN bridge_service_tasks t ON t.task_id = i.task_id
              WHERE i.parent_session_id = ? AND i.child_id = ? AND i.request_id = ?
              """,
            arguments: [parentSessionID, childID, requestID])
        else { return nil }
        let rawTaskID: String? = row["task_id"]
        let rawStatus: String? = row["status"]
        return EmbeddedDSHInputState(
          taskID: rawTaskID.map { TaskID(rawValue: $0) },
          status: rawStatus.flatMap(ServiceTaskStatus.init(rawValue:)))
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  /// The workbench child that owns the task, or nil for any other task.
  public func embeddedDSHSubagentIdentity(taskID: TaskID) throws -> EmbeddedDSHSubagentIdentity? {
    do {
      return try database.read { db in
        try Row.fetchOne(
          db,
          sql: """
            SELECT parent_session_id, child_id FROM bridge_service_embedded_dsh_inputs
            WHERE task_id = ? LIMIT 1
            """,
          arguments: [taskID.rawValue]
        ).map {
          EmbeddedDSHSubagentIdentity(
            parentSessionID: $0["parent_session_id"], childID: $0["child_id"])
        }
      }
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }
}
