import Foundation
import GRDB

extension SimpleServiceStore {
  public func createWorkbenchConversation(
    logicalSessionID: String, nativeSessionID: String, projectID: String? = nil,
    at date: Date = Date()
  ) throws -> ServiceWorkbenchConversation {
    try Self.validateWorkbenchIdentifier(logicalSessionID)
    try Self.validateWorkbenchIdentifier(nativeSessionID)
    if let projectID { try Self.validateWorkbenchIdentifier(projectID) }
    try ServiceValidation.date(date, field: "conversation.date")
    do {
      return try database.write { db in
        if let current = try Self.workbenchConversation(logicalSessionID: logicalSessionID, in: db)
        {
          guard
            let original = try Row.fetchOne(
              db,
              sql: """
                SELECT native_session_id, project_id FROM bridge_service_workbench_segments
                WHERE logical_session_id = ? AND ordinal = 0
                """, arguments: [logicalSessionID]),
            original["native_session_id"] as String == nativeSessionID,
            original["project_id"] as String? == projectID
          else { throw ServiceStoreError.invalidArgument("conversation.bindingConflict") }
          return current
        }
        guard try Self.workbenchConversation(nativeSessionID: nativeSessionID, in: db) == nil else {
          throw ServiceStoreError.invalidArgument("conversation.nativeConflict")
        }
        try db.execute(
          sql: """
            INSERT INTO bridge_service_workbench_conversations
              (logical_session_id, native_session_id, project_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
            """,
          arguments: [
            logicalSessionID, nativeSessionID, projectID, date.timeIntervalSince1970,
            date.timeIntervalSince1970,
          ])
        try db.execute(
          sql: """
            INSERT INTO bridge_service_workbench_segments
              (logical_session_id, native_session_id, ordinal, project_id, created_at) VALUES (?, ?, 0, ?, ?)
            """,
          arguments: [logicalSessionID, nativeSessionID, projectID, date.timeIntervalSince1970])
        guard
          let result = try Self.workbenchConversation(logicalSessionID: logicalSessionID, in: db)
        else {
          throw ServiceStoreError.corruptRecord
        }
        return result
      }
    } catch let error as ServiceStoreError { throw error } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func workbenchConversation(logicalSessionID: String) throws
    -> ServiceWorkbenchConversation?
  {
    try Self.validateWorkbenchIdentifier(logicalSessionID)
    do {
      return try database.read {
        try Self.workbenchConversation(logicalSessionID: logicalSessionID, in: $0)
      }
    } catch let error as ServiceStoreError { throw error } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func workbenchConversation(nativeSessionID: String) throws -> ServiceWorkbenchConversation?
  {
    try Self.validateWorkbenchIdentifier(nativeSessionID)
    do {
      return try database.read {
        try Self.workbenchConversation(nativeSessionID: nativeSessionID, in: $0)
      }
    } catch let error as ServiceStoreError { throw error } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func workbenchConversations(
    limit: Int = 500, before: ServiceWorkbenchConversationCursor? = nil
  ) throws -> [ServiceWorkbenchConversation] {
    guard (1...2_000).contains(limit) else {
      throw ServiceStoreError.invalidArgument("conversation.limit")
    }
    if let before {
      try Self.validateWorkbenchIdentifier(before.logicalSessionID)
      try ServiceValidation.date(before.updatedAt, field: "conversation.cursorDate")
    }
    do {
      return try database.read { db in
        let rows: [Row]
        if let before {
          rows = try Row.fetchAll(
            db,
            sql: """
              SELECT * FROM bridge_service_workbench_conversations
              WHERE updated_at < ? OR (updated_at = ? AND logical_session_id > ?)
              ORDER BY updated_at DESC, logical_session_id LIMIT ?
              """,
            arguments: [
              before.updatedAt.timeIntervalSince1970, before.updatedAt.timeIntervalSince1970,
              before.logicalSessionID, limit,
            ])
        } else {
          rows = try Row.fetchAll(
            db,
            sql:
              "SELECT * FROM bridge_service_workbench_conversations ORDER BY updated_at DESC, logical_session_id LIMIT ?",
            arguments: [limit])
        }
        return rows.map(Self.decodeWorkbenchConversation)
      }
    } catch let error as ServiceStoreError { throw error } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func workbenchSegments(logicalSessionID: String) throws -> [ServiceWorkbenchSegment] {
    try Self.validateWorkbenchIdentifier(logicalSessionID)
    do {
      return try database.read { db in
        try Row.fetchAll(
          db,
          sql:
            "SELECT * FROM bridge_service_workbench_segments WHERE logical_session_id = ? ORDER BY ordinal",
          arguments: [logicalSessionID]
        ).map { row in
          ServiceWorkbenchSegment(
            logicalSessionID: row["logical_session_id"], nativeSessionID: row["native_session_id"],
            ordinal: row["ordinal"], projectID: row["project_id"],
            createdAt: Date(timeIntervalSince1970: row["created_at"]))
        }
      }
    } catch { throw ServiceStoreError.storageFailure }
  }

  static func validateWorkbenchIdentifier(_ value: String) throws {
    try ServiceValidation.identifier(value, field: "conversation.identifier", maximumBytes: 1_024)
  }

  static func workbenchConversation(logicalSessionID: String, in db: Database) throws
    -> ServiceWorkbenchConversation?
  {
    try Row.fetchOne(
      db, sql: "SELECT * FROM bridge_service_workbench_conversations WHERE logical_session_id = ?",
      arguments: [logicalSessionID]
    ).map(Self.decodeWorkbenchConversation)
  }

  static func workbenchConversation(nativeSessionID: String, in db: Database) throws
    -> ServiceWorkbenchConversation?
  {
    try Row.fetchOne(
      db,
      sql: """
        SELECT c.* FROM bridge_service_workbench_conversations c
        JOIN bridge_service_workbench_segments s ON s.logical_session_id = c.logical_session_id
        WHERE s.native_session_id = ?
        """, arguments: [nativeSessionID]
    ).map(Self.decodeWorkbenchConversation)
  }

  private static func decodeWorkbenchConversation(_ row: Row) -> ServiceWorkbenchConversation {
    ServiceWorkbenchConversation(
      logicalSessionID: row["logical_session_id"], nativeSessionID: row["native_session_id"],
      projectID: row["project_id"], createdAt: Date(timeIntervalSince1970: row["created_at"]),
      updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
  }
}
