import BridgeDomain
import Foundation
import GRDB

public struct SubagentRoundInsertion: Equatable, Sendable {
  public let round: SubagentRound
  /// `false`: the key already existed with the same fingerprint and `round` is the stored row.
  public let created: Bool
}

extension SimpleServiceStore {
  /// Inserts a round. Idempotent on the key: the same fingerprint returns the stored row, another
  /// fingerprint throws `invalidArgument("subagentRound.idempotencyConflict")`.
  public func insertSubagentRound(_ draft: SubagentRoundDraft) throws -> SubagentRoundInsertion {
    try SubagentRound(draft: draft, ordinal: 1).validate()
    do {
      return try database.write { db in
        if let existing = try Self.subagentRound(draft.key, in: db) {
          guard existing.fingerprint == draft.fingerprint else {
            throw ServiceStoreError.invalidArgument("subagentRound.idempotencyConflict")
          }
          return SubagentRoundInsertion(round: existing, created: false)
        }
        guard
          try Bool.fetchOne(
            db, sql: "SELECT 1 FROM bridge_service_projects WHERE project_id = ?",
            arguments: [draft.projectID.rawValue]) != nil
        else { throw ServiceStoreError.unknownProject(draft.projectID) }
        let ordinal =
          (try Int64.fetchOne(
            db, sql: "SELECT COALESCE(MAX(ordinal), 0) FROM \(SubagentRoundCodec.table)") ?? 0) + 1
        try db.execute(
          sql: """
            INSERT INTO \(SubagentRoundCodec.table) (\(SubagentRoundCodec.insertColumns))
            VALUES (\(SubagentRoundCodec.insertPlaceholders))
            """,
          arguments: try SubagentRoundCodec.arguments(SubagentRound(draft: draft, ordinal: ordinal))
        )
        // Return the row as stored: the time columns are rounded to a `Double`.
        guard let stored = try Self.subagentRound(draft.key, in: db) else {
          throw ServiceStoreError.corruptRecord
        }
        return SubagentRoundInsertion(round: stored, created: true)
      }
    } catch let error as ServiceStoreError { throw error } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func subagentRound(_ key: SubagentRoundKey) throws -> SubagentRound? {
    try readSubagentRounds { try Self.subagentRound(key, in: $0) }
  }

  /// Every round of one root, oldest first.
  public func subagentRounds(rootID: String) throws -> [SubagentRound] {
    try ServiceValidation.identifier(rootID, field: "subagentRound.rootID", maximumBytes: 256)
    return try readSubagentRounds { db in
      try Row.fetchAll(
        db,
        sql: "SELECT * FROM \(SubagentRoundCodec.table) WHERE root_id = ? ORDER BY ordinal",
        arguments: [rootID]
      ).map(SubagentRoundCodec.decode)
    }
  }

  public func subagentRounds(rootID: String, childID: String) throws -> [SubagentRound] {
    try ServiceValidation.identifier(rootID, field: "subagentRound.rootID", maximumBytes: 256)
    try ServiceValidation.identifier(childID, field: "subagentRound.childID", maximumBytes: 256)
    return try readSubagentRounds { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM \(SubagentRoundCodec.table)
          WHERE root_id = ? AND child_id = ? ORDER BY ordinal
          """,
        arguments: [rootID, childID]
      ).map(SubagentRoundCodec.decode)
    }
  }

  /// Roots that still have work to do: a round that is queued, being dispatched, running or
  /// unconfirmed, a finished round whose result or failure notice is not delivered yet, or a round
  /// that still holds a reservation or lease. Mirrors `SubagentRoundRetention.isFinished`.
  public func rootsWithOpenSubagentRounds() throws -> [String] {
    try readSubagentRounds { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT DISTINCT root_id FROM \(SubagentRoundCodec.table)
          WHERE phase IN ('queued', 'dispatching', 'unknown', 'delivery_unknown', 'running')
            OR reservation_held = 1 OR lease_held = 1
            OR (delivery_required = 1 AND delivered = 0 AND phase IN ('settled', 'failed'))
          ORDER BY root_id
          """)
    }
  }

  /// Every root that has any round, open or not; the retention sweep walks these.
  public func subagentRoundRootIDs() throws -> [String] {
    try readSubagentRounds { db in
      try String.fetchAll(
        db,
        sql: "SELECT DISTINCT root_id FROM \(SubagentRoundCodec.table) ORDER BY root_id")
    }
  }

  /// The roots that have rounds for this child. A child ID is only ever created under one root;
  /// callers use this to tell a child of another root from an unknown one.
  public func subagentRoundRoots(ofChild childID: String) throws -> [String] {
    try ServiceValidation.identifier(childID, field: "subagentRound.childID", maximumBytes: 256)
    return try readSubagentRounds { db in
      try String.fetchAll(
        db,
        sql:
          "SELECT DISTINCT root_id FROM \(SubagentRoundCodec.table) WHERE child_id = ? ORDER BY root_id",
        arguments: [childID])
    }
  }

  static func subagentRound(_ key: SubagentRoundKey, in db: Database) throws -> SubagentRound? {
    try Row.fetchOne(
      db,
      sql: """
        SELECT * FROM \(SubagentRoundCodec.table)
        WHERE root_id = ? AND child_id = ? AND request_id = ?
        """,
      arguments: [key.rootID, key.childID, key.requestID]
    ).map(SubagentRoundCodec.decode)
  }

  func readSubagentRounds<T>(_ read: (Database) throws -> T) throws -> T {
    do {
      return try database.read(read)
    } catch let error as ServiceStoreError { throw error } catch {
      throw ServiceStoreError.storageFailure
    }
  }
}
