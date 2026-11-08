import Foundation
import GRDB

extension SimpleServiceStore {
  public func workbenchGeneration(sessionID: String) throws -> ServiceWorkbenchGeneration {
    try ServiceValidation.identifier(sessionID, field: "operation.sessionID", maximumBytes: 1_024)
    do {
      return try database.write { db in
        try db.execute(
          sql: "INSERT OR IGNORE INTO bridge_service_workbench_generations VALUES (?, 0, 0)",
          arguments: [sessionID])
        guard
          let row = try Row.fetchOne(
            db,
            sql:
              "SELECT generation, closed FROM bridge_service_workbench_generations WHERE session_id = ?",
            arguments: [sessionID])
        else { throw ServiceStoreError.corruptRecord }
        return ServiceWorkbenchGeneration(
          sessionID: sessionID, generation: row["generation"], closed: (row["closed"] as Int) != 0)
      }
    } catch let error as ServiceStoreError { throw error } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func closeWorkbenchGeneration(
    sessionID: String, generation: Int64, at date: Date = Date()
  ) throws {
    try ServiceValidation.identifier(sessionID, field: "operation.sessionID", maximumBytes: 1_024)
    try ServiceValidation.date(date, field: "operation.date")
    do {
      try database.write { db in
        guard
          let row = try Row.fetchOne(
            db,
            sql: "SELECT generation FROM bridge_service_workbench_generations WHERE session_id = ?",
            arguments: [sessionID]), row["generation"] as Int64 == generation
        else { throw ServiceStoreError.invalidArgument("operation.generationConflict") }
        try Self.closeWorkbenchGeneration(
          sessionID: sessionID, generation: generation, at: date, in: db)
      }
    } catch let error as ServiceStoreError { throw error } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func advanceWorkbenchGeneration(
    sessionID: String, expectedGeneration: Int64
  ) throws -> ServiceWorkbenchGeneration {
    try ServiceValidation.identifier(sessionID, field: "operation.sessionID", maximumBytes: 1_024)
    guard expectedGeneration >= 0, expectedGeneration < Int64.max else {
      throw ServiceStoreError.invalidArgument("operation.generation")
    }
    do {
      return try database.write { db in
        try db.execute(
          sql: """
            UPDATE bridge_service_workbench_generations SET generation = generation + 1, closed = 0
            WHERE session_id = ? AND generation = ? AND closed = 1
            """, arguments: [sessionID, expectedGeneration])
        guard db.changesCount == 1 else {
          throw ServiceStoreError.invalidArgument("operation.generationConflict")
        }
        return ServiceWorkbenchGeneration(
          sessionID: sessionID, generation: expectedGeneration + 1, closed: false)
      }
    } catch let error as ServiceStoreError { throw error } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  static func ensureWorkbenchGeneration(sessionID: String, generation: Int64, in db: Database)
    throws
  {
    try db.execute(
      sql: "INSERT OR IGNORE INTO bridge_service_workbench_generations VALUES (?, ?, 0)",
      arguments: [sessionID, generation])
    guard
      let row = try Row.fetchOne(
        db,
        sql:
          "SELECT generation, closed FROM bridge_service_workbench_generations WHERE session_id = ?",
        arguments: [sessionID]), row["generation"] as Int64 == generation, row["closed"] as Int == 0
    else { throw ServiceStoreError.invalidArgument("operation.generationClosed") }
  }

  static func closeWorkbenchGeneration(
    sessionID: String, generation: Int64, at date: Date,
    in db: Database
  ) throws {
    try db.execute(
      sql:
        "UPDATE bridge_service_workbench_generations SET closed = 1 WHERE session_id = ? AND generation = ?",
      arguments: [sessionID, generation])
    guard db.changesCount == 1 else { return }
    try db.execute(
      sql: """
        UPDATE bridge_service_workbench_operations SET cancelled = 1,
          phase = CASE WHEN phase = 'recorded' THEN 'cancelled' ELSE phase END,
          version = version + 1, updated_at = ?
        WHERE session_id = ? AND generation = ? AND cancelled = 0
          AND kind != 'session.stop'
          AND phase NOT IN ('completed', 'failed', 'cancelled')
        """, arguments: [date.timeIntervalSince1970, sessionID, generation])
  }
}
