import Foundation
import GRDB

extension SimpleServiceStore {
  public func upsertWorkbenchPendingInteraction(_ interaction: ServiceWorkbenchPendingInteraction)
    throws
  {
    for value in [
      interaction.logicalSessionID, interaction.interactionID, interaction.nativeSessionID,
      interaction.kind,
    ] {
      try Self.validateWorkbenchIdentifier(value)
    }
    guard interaction.eventSeq >= 0 else {
      throw ServiceStoreError.invalidArgument("interaction.eventSeq")
    }
    try ServiceValidation.date(interaction.updatedAt, field: "interaction.date")
    do {
      try database.write { db in
        try db.execute(
          sql: """
            INSERT INTO bridge_service_workbench_pending_interactions
              (logical_session_id, interaction_id, native_session_id, kind, event_seq, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(logical_session_id, interaction_id) DO UPDATE SET
              native_session_id = excluded.native_session_id, kind = excluded.kind,
              event_seq = excluded.event_seq, updated_at = excluded.updated_at
            WHERE excluded.event_seq >= bridge_service_workbench_pending_interactions.event_seq
            """,
          arguments: [
            interaction.logicalSessionID, interaction.interactionID, interaction.nativeSessionID,
            interaction.kind, interaction.eventSeq, interaction.updatedAt.timeIntervalSince1970,
          ])
      }
    } catch { throw ServiceStoreError.storageFailure }
  }

  public func removeWorkbenchPendingInteraction(
    logicalSessionID: String, interactionID: String, throughEventSeq: Int64
  ) throws {
    try Self.validateWorkbenchIdentifier(logicalSessionID)
    try Self.validateWorkbenchIdentifier(interactionID)
    guard throughEventSeq >= 0 else {
      throw ServiceStoreError.invalidArgument("interaction.eventSeq")
    }
    do {
      try database.write { db in
        try db.execute(
          sql: """
            DELETE FROM bridge_service_workbench_pending_interactions
            WHERE logical_session_id = ? AND interaction_id = ? AND event_seq <= ?
            """, arguments: [logicalSessionID, interactionID, throughEventSeq])
      }
    } catch { throw ServiceStoreError.storageFailure }
  }

  public func workbenchPendingInteractions(
    logicalSessionID: String? = nil, limit: Int = 100
  ) throws -> [ServiceWorkbenchPendingInteraction] {
    if let logicalSessionID { try Self.validateWorkbenchIdentifier(logicalSessionID) }
    guard (1...500).contains(limit) else {
      throw ServiceStoreError.invalidArgument("interaction.limit")
    }
    do {
      return try database.read { db in
        let rows: [Row]
        if let logicalSessionID {
          rows = try Row.fetchAll(
            db,
            sql: """
              SELECT * FROM bridge_service_workbench_pending_interactions WHERE logical_session_id = ?
              ORDER BY updated_at DESC, interaction_id LIMIT ?
              """, arguments: [logicalSessionID, limit])
        } else {
          rows = try Row.fetchAll(
            db,
            sql: """
              SELECT * FROM bridge_service_workbench_pending_interactions
              ORDER BY updated_at DESC, interaction_id LIMIT ?
              """, arguments: [limit])
        }
        return rows.map { row in
          ServiceWorkbenchPendingInteraction(
            logicalSessionID: row["logical_session_id"], interactionID: row["interaction_id"],
            nativeSessionID: row["native_session_id"], kind: row["kind"],
            eventSeq: row["event_seq"],
            updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
        }
      }
    } catch { throw ServiceStoreError.storageFailure }
  }
}
