import BridgeDomain
import GRDB

extension SimpleServiceStore {
  public func pendingEmbeddedDSHResults(parentSessionID: String) throws
    -> [EmbeddedDSHSubagentResult]
  {
    try ServiceValidation.identifier(parentSessionID, field: "dsh.sessionID", maximumBytes: 1_024)
    do {
      return try database.read { db in
        let rows = try Row.fetchAll(
          db,
          sql: """
            SELECT i.parent_session_id, i.child_id, i.request_id, i.task_id,
                   t.status, t.result_summary, t.failure_code
            FROM bridge_service_embedded_dsh_inputs i
            JOIN bridge_service_tasks t ON t.task_id = i.task_id
            WHERE i.parent_session_id = ? AND i.result_delivered = 0
              AND t.status IN ('completed', 'failed', 'interrupted')
            ORDER BY t.updated_at, i.child_id, i.request_id
            """,
          arguments: [parentSessionID]
        )
        return try rows.map { row in
          guard let status = ServiceTaskStatus(rawValue: row["status"]), status.isTerminal else {
            throw ServiceStoreError.corruptRecord
          }
          return EmbeddedDSHSubagentResult(
            parentSessionID: row["parent_session_id"], childID: row["child_id"],
            requestID: row["request_id"], taskID: TaskID(rawValue: row["task_id"]),
            status: status, resultSummary: row["result_summary"], failureCode: row["failure_code"]
          )
        }
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func acknowledgeEmbeddedDSHResult(
    parentSessionID: String, childID: String, requestID: String, taskID: TaskID
  ) throws {
    try Self.validateEmbeddedDSHIdentity(.init(parentSessionID: parentSessionID, childID: childID))
    try ServiceValidation.identifier(requestID, field: "dsh.requestID", maximumBytes: 1_024)
    do {
      try database.write { db in
        try db.execute(
          sql: """
            UPDATE bridge_service_embedded_dsh_inputs SET result_delivered = 1
            WHERE parent_session_id = ? AND child_id = ? AND request_id = ? AND task_id = ?
              AND EXISTS (
                SELECT 1 FROM bridge_service_tasks t WHERE t.task_id = ?
                  AND t.status IN ('completed', 'failed', 'interrupted')
              )
            """,
          arguments: [parentSessionID, childID, requestID, taskID.rawValue, taskID.rawValue]
        )
        guard db.changesCount == 1 else {
          throw ServiceStoreError.invalidArgument("dsh.resultIdentity")
        }
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }
}
