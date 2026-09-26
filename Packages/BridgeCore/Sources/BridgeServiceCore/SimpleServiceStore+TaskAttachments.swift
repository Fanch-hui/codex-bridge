import BridgeAgentCore
import BridgeDomain
import GRDB

extension SimpleServiceStore {
  public func taskAttachments(taskIDs: [TaskID]) throws -> [TaskID: [AgentImageAttachment]] {
    guard !taskIDs.isEmpty else { return [:] }
    let uniqueIDs = Array(Set(taskIDs))
    do {
      return try database.read { db in
        let placeholders = Array(repeating: "?", count: uniqueIDs.count).joined(separator: ", ")
        let rows = try Row.fetchAll(
          db,
          sql: """
            SELECT task_id, relative_path, mime_type, byte_count, sha256
            FROM bridge_service_task_attachments
            WHERE task_id IN (\(placeholders))
            ORDER BY task_id, position
            """,
          arguments: StatementArguments(uniqueIDs.map(\.rawValue))
        )
        var result = Dictionary(
          uniqueKeysWithValues: uniqueIDs.map { ($0, [AgentImageAttachment]()) })
        for row in rows {
          let taskID = TaskID(rawValue: row["task_id"])
          result[taskID, default: []].append(
            try AgentImageAttachment(
              relativePath: row["relative_path"],
              mimeType: row["mime_type"],
              byteCount: row["byte_count"],
              sha256: row["sha256"]
            )
          )
        }
        return result
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func taskAttachments(taskID: TaskID) throws -> [AgentImageAttachment] {
    do {
      return try database.read { db in
        try Self.taskAttachments(taskID: taskID.rawValue, in: db)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  static func insertTaskAttachments(
    _ attachments: [AgentImageAttachment],
    taskID: TaskID,
    in db: Database
  ) throws {
    try validateTaskAttachments(attachments)
    for (position, attachment) in attachments.enumerated() {
      try db.execute(
        sql: """
          INSERT INTO bridge_service_task_attachments
            (task_id, position, relative_path, mime_type, byte_count, sha256)
          VALUES (?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          taskID.rawValue, position, attachment.relativePath, attachment.mimeType,
          attachment.byteCount, attachment.sha256,
        ]
      )
    }
  }

  static func taskAttachments(taskID: String, in db: Database) throws
    -> [AgentImageAttachment]
  {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT relative_path, mime_type, byte_count, sha256
        FROM bridge_service_task_attachments
        WHERE task_id = ?
        ORDER BY position
        """,
      arguments: [taskID]
    )
    return try rows.map { row in
      try AgentImageAttachment(
        relativePath: row["relative_path"],
        mimeType: row["mime_type"],
        byteCount: row["byte_count"],
        sha256: row["sha256"]
      )
    }
  }

  static func validateTaskAttachments(_ attachments: [AgentImageAttachment]) throws {
    guard attachments.count <= AgentImageAttachmentLimits.maximumCount,
      Set(attachments.map(\.relativePath)).count == attachments.count,
      attachments.reduce(Int64(0), { $0 + $1.byteCount })
        <= AgentImageAttachmentLimits.maximumTotalBytes
    else {
      throw ServiceStoreError.invalidArgument("task.attachments")
    }
  }
}
