import BridgeDomain
import GRDB

public struct EmbeddedDSHHistoryMessage: Sendable {
  public let message: ServiceTaskMessageRecord
  public let taskStatus: ServiceTaskStatus
  public let requestID: String
  public let runID: String?
}

extension SimpleServiceStore {
  public func embeddedDSHMessages(
    parentSessionID: String, childID: String, beforeMessageID: Int64?, limit: Int
  ) throws -> [EmbeddedDSHHistoryMessage] {
    try ServiceValidation.identifier(
      parentSessionID, field: "dsh.parentSessionID", maximumBytes: 1_024)
    try ServiceValidation.identifier(childID, field: "dsh.childID", maximumBytes: 1_024)
    guard (1...501).contains(limit), beforeMessageID.map({ $0 > 0 }) != false else {
      throw ServiceStoreError.invalidArgument("dsh.historyPage")
    }
    do {
      return try database.read { db in
        let rows = try Row.fetchAll(
          db,
          sql: """
            SELECT * FROM (
              SELECT m.*, t.status AS history_status, i.request_id AS history_request_id,
                     COALESCE(t.provider_run_id, t.codex_turn_id) AS history_run_id
              FROM bridge_service_embedded_dsh_inputs i
              JOIN bridge_service_tasks t ON t.task_id = i.task_id
              JOIN bridge_service_task_messages m ON m.task_id = t.task_id
              WHERE i.parent_session_id = ? AND i.child_id = ?
                AND (? IS NULL OR m.message_id < ?)
              ORDER BY m.message_id DESC
              LIMIT ?
            ) ORDER BY message_id ASC
            """,
          arguments: [parentSessionID, childID, beforeMessageID, beforeMessageID, limit])
        return try rows.map { row in
          guard let status = ServiceTaskStatus(rawValue: row["history_status"]) else {
            throw ServiceStoreError.corruptRecord
          }
          return EmbeddedDSHHistoryMessage(
            message: try Self.decodeTaskMessage(row), taskStatus: status,
            requestID: row["history_request_id"], runID: row["history_run_id"])
        }
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }
}
