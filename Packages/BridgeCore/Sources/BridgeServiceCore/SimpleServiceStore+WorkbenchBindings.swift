import Foundation
import GRDB

extension SimpleServiceStore {
  public func prepareWorkbenchProjectBinding(
    logicalSessionID: String, targetNativeSessionID: String, projectID: String,
    requestID: String, toolCallID: String, at date: Date = Date()
  ) throws -> ServiceWorkbenchBinding {
    for value in [logicalSessionID, targetNativeSessionID, projectID, requestID, toolCallID] {
      try Self.validateWorkbenchIdentifier(value)
    }
    try ServiceValidation.date(date, field: "conversation.date")
    do {
      return try database.write { db in
        if let previous = try Self.workbenchBinding(logicalSessionID: logicalSessionID, in: db),
          previous.phase != .cancelled
        {
          guard previous.targetNativeSessionID == targetNativeSessionID,
            previous.projectID == projectID, previous.requestID == requestID,
            previous.toolCallID == toolCallID
          else { throw ServiceStoreError.invalidArgument("conversation.bindingConflict") }
          return previous
        }
        guard
          let conversation = try Self.workbenchConversation(
            logicalSessionID: logicalSessionID, in: db),
          conversation.projectID == nil, conversation.nativeSessionID != targetNativeSessionID,
          try Self.workbenchConversation(nativeSessionID: targetNativeSessionID, in: db) == nil
        else { throw ServiceStoreError.invalidArgument("conversation.bindingScope") }
        try db.execute(
          sql:
            "DELETE FROM bridge_service_workbench_bindings WHERE logical_session_id = ? AND phase = 'cancelled'",
          arguments: [logicalSessionID])
        try db.execute(
          sql: """
            INSERT INTO bridge_service_workbench_bindings
              (logical_session_id, source_native_session_id, target_native_session_id, project_id,
               request_id, tool_call_id, boundary_seq, phase, version, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, NULL, 'prepared', 1, ?, ?)
            """,
          arguments: [
            logicalSessionID, conversation.nativeSessionID, targetNativeSessionID, projectID,
            requestID, toolCallID, date.timeIntervalSince1970, date.timeIntervalSince1970,
          ])
        guard let result = try Self.workbenchBinding(logicalSessionID: logicalSessionID, in: db)
        else {
          throw ServiceStoreError.corruptRecord
        }
        return result
      }
    } catch let error as ServiceStoreError { throw error } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func workbenchProjectBinding(logicalSessionID: String) throws -> ServiceWorkbenchBinding? {
    try Self.validateWorkbenchIdentifier(logicalSessionID)
    do {
      return try database.read {
        try Self.workbenchBinding(logicalSessionID: logicalSessionID, in: $0)
      }
    } catch let error as ServiceStoreError { throw error } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func pendingWorkbenchProjectBindings(limit: Int = 100) throws -> [ServiceWorkbenchBinding]
  {
    guard (1...500).contains(limit) else {
      throw ServiceStoreError.invalidArgument("conversation.limit")
    }
    do {
      return try database.read { db in
        try Row.fetchAll(
          db,
          sql: """
            SELECT * FROM bridge_service_workbench_bindings WHERE phase NOT IN ('committed', 'cancelled')
            ORDER BY updated_at, logical_session_id LIMIT ?
            """, arguments: [limit]
        ).map(Self.decodeWorkbenchBinding)
      }
    } catch let error as ServiceStoreError { throw error } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func advanceWorkbenchProjectBinding(
    logicalSessionID: String, expectedVersion: Int64, phase: ServiceWorkbenchBindingPhase,
    boundarySeq: Int64? = nil, at date: Date = Date()
  ) throws -> ServiceWorkbenchBinding {
    try Self.validateWorkbenchIdentifier(logicalSessionID)
    try ServiceValidation.date(date, field: "conversation.date")
    guard boundarySeq.map({ $0 >= -1 }) ?? true else {
      throw ServiceStoreError.invalidArgument("conversation.boundary")
    }
    do {
      return try database.write { db in
        guard let old = try Self.workbenchBinding(logicalSessionID: logicalSessionID, in: db) else {
          throw ServiceStoreError.invalidArgument("conversation.bindingNotFound")
        }
        guard old.version == expectedVersion else {
          throw ServiceStoreError.invalidArgument("conversation.versionConflict")
        }
        guard Self.allowedWorkbenchBindingTransition(old.phase, phase),
          old.boundarySeq == nil || boundarySeq == nil || old.boundarySeq == boundarySeq,
          phase != .oldStopped || old.boundarySeq != nil || boundarySeq != nil
        else { throw ServiceStoreError.invalidArgument("conversation.bindingTransition") }
        if phase == .committed { try Self.commitWorkbenchBinding(old, at: date, in: db) }
        try db.execute(
          sql: """
            UPDATE bridge_service_workbench_bindings SET phase = ?, boundary_seq = COALESCE(boundary_seq, ?),
              version = version + 1, updated_at = ? WHERE logical_session_id = ? AND version = ?
            """,
          arguments: [
            phase.rawValue, boundarySeq, date.timeIntervalSince1970, logicalSessionID,
            expectedVersion,
          ])
        guard let result = try Self.workbenchBinding(logicalSessionID: logicalSessionID, in: db)
        else {
          throw ServiceStoreError.corruptRecord
        }
        return result
      }
    } catch let error as ServiceStoreError { throw error } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func finishStoppedWorkbenchProjectBinding(
    logicalSessionID: String,
    expectedVersion: Int64, boundarySeq: Int64, at date: Date = Date()
  ) throws -> ServiceWorkbenchBinding {
    try Self.validateWorkbenchIdentifier(logicalSessionID)
    try ServiceValidation.date(date, field: "conversation.date")
    guard boundarySeq >= -1 else {
      throw ServiceStoreError.invalidArgument("conversation.boundary")
    }
    do {
      return try database.write { db in
        guard let old = try Self.workbenchBinding(logicalSessionID: logicalSessionID, in: db),
          old.version == expectedVersion, old.phase != .cancelled, old.phase != .committed,
          old.boundarySeq == nil || old.boundarySeq == boundarySeq
        else { throw ServiceStoreError.invalidArgument("conversation.bindingTransition") }
        try Self.commitWorkbenchBinding(old, at: date, in: db)
        try db.execute(
          sql: """
            UPDATE bridge_service_workbench_bindings SET phase = 'committed', boundary_seq = ?,
              version = version + 1, updated_at = ? WHERE logical_session_id = ? AND version = ?
            """,
          arguments: [boundarySeq, date.timeIntervalSince1970, logicalSessionID, expectedVersion])
        guard let result = try Self.workbenchBinding(logicalSessionID: logicalSessionID, in: db)
        else {
          throw ServiceStoreError.corruptRecord
        }
        return result
      }
    } catch let error as ServiceStoreError { throw error } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  private static func commitWorkbenchBinding(
    _ binding: ServiceWorkbenchBinding, at date: Date, in db: Database
  ) throws {
    guard
      let conversation = try workbenchConversation(
        logicalSessionID: binding.logicalSessionID, in: db),
      conversation.nativeSessionID == binding.sourceNativeSessionID, conversation.projectID == nil,
      try workbenchConversation(nativeSessionID: binding.targetNativeSessionID, in: db) == nil
    else { throw ServiceStoreError.invalidArgument("conversation.bindingScope") }
    let ordinal =
      (try Int64.fetchOne(
        db,
        sql:
          "SELECT MAX(ordinal) FROM bridge_service_workbench_segments WHERE logical_session_id = ?",
        arguments: [binding.logicalSessionID]) ?? -1) + 1
    try db.execute(
      sql: """
        INSERT INTO bridge_service_workbench_segments
          (logical_session_id, native_session_id, ordinal, project_id, created_at) VALUES (?, ?, ?, ?, ?)
        """,
      arguments: [
        binding.logicalSessionID, binding.targetNativeSessionID, ordinal, binding.projectID,
        date.timeIntervalSince1970,
      ])
    try db.execute(
      sql: """
        UPDATE bridge_service_workbench_conversations SET native_session_id = ?, project_id = ?, updated_at = ?
        WHERE logical_session_id = ?
        """,
      arguments: [
        binding.targetNativeSessionID, binding.projectID, date.timeIntervalSince1970,
        binding.logicalSessionID,
      ])
  }

  private static func allowedWorkbenchBindingTransition(
    _ old: ServiceWorkbenchBindingPhase, _ new: ServiceWorkbenchBindingPhase
  ) -> Bool {
    switch (old, new) {
    case (.prepared, .oldStopped), (.oldStopped, .segmentCreated),
      (.segmentCreated, .continuationEnqueued), (.continuationEnqueued, .committed),
      (.prepared, .cancelled), (.oldStopped, .cancelled), (.segmentCreated, .cancelled):
      return true
    default: return false
    }
  }

  private static func workbenchBinding(logicalSessionID: String, in db: Database) throws
    -> ServiceWorkbenchBinding?
  {
    try Row.fetchOne(
      db, sql: "SELECT * FROM bridge_service_workbench_bindings WHERE logical_session_id = ?",
      arguments: [logicalSessionID]
    ).map(Self.decodeWorkbenchBinding)
  }

  private static func decodeWorkbenchBinding(_ row: Row) throws -> ServiceWorkbenchBinding {
    guard let phase = ServiceWorkbenchBindingPhase(rawValue: row["phase"]) else {
      throw ServiceStoreError.corruptRecord
    }
    return ServiceWorkbenchBinding(
      logicalSessionID: row["logical_session_id"],
      sourceNativeSessionID: row["source_native_session_id"],
      targetNativeSessionID: row["target_native_session_id"], projectID: row["project_id"],
      requestID: row["request_id"], toolCallID: row["tool_call_id"],
      boundarySeq: row["boundary_seq"],
      phase: phase, version: row["version"],
      createdAt: Date(timeIntervalSince1970: row["created_at"]),
      updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
  }
}
