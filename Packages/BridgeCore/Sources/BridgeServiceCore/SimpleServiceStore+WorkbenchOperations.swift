import Crypto
import Foundation
import GRDB

extension SimpleServiceStore {
  public func registerWorkbenchOperation(
    _ draft: ServiceWorkbenchOperationDraft, generation: Int64, at date: Date = Date()
  ) throws -> ServiceWorkbenchOperationRegistration {
    try Self.validateWorkbenchDraft(draft)
    try ServiceValidation.date(date, field: "operation.date")
    guard generation >= 0 else { throw ServiceStoreError.invalidArgument("operation.generation") }
    let object = try JSONSerialization.jsonObject(with: Data(draft.inputJSON.utf8))
    let canonicalInput = String(
      decoding: try JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    let canonicalDraft = ServiceWorkbenchOperationDraft(
      operationID: draft.operationID, kind: draft.kind, sessionID: draft.sessionID,
      childID: draft.childID, projectID: draft.projectID, targetID: draft.targetID,
      requestID: draft.requestID, inputJSON: canonicalInput)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let digest = try SHA256.hash(data: encoder.encode(canonicalDraft)).map {
      String(format: "%02x", $0)
    }
    .joined()
    do {
      return try database.write { db in
        if let previous = try Self.workbenchOperation(id: draft.operationID, in: db) {
          guard previous.inputDigest == digest else {
            throw ServiceStoreError.invalidArgument("operation.idempotencyConflict")
          }
          if previous.draft.kind == "session.stop", !previous.phase.isTerminal,
            let sessionID = previous.draft.sessionID
          {
            try Self.closeWorkbenchGeneration(
              sessionID: sessionID,
              generation: previous.generation, at: date, in: db)
          }
          return ServiceWorkbenchOperationRegistration(operation: previous, created: false)
        }
        if let sessionID = draft.sessionID {
          try Self.ensureWorkbenchGeneration(sessionID: sessionID, generation: generation, in: db)
        }
        try db.execute(
          sql: """
            INSERT INTO bridge_service_workbench_operations
              (operation_id, kind, session_id, child_id, project_id, target_id, request_id,
               generation, input_json, input_digest, phase, result_target_id, result_json,
               cancelled, version, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'recorded', NULL, NULL, 0, 1, ?, ?)
            """,
          arguments: [
            draft.operationID, draft.kind, draft.sessionID, draft.childID, draft.projectID,
            draft.targetID, draft.requestID, generation, canonicalInput, digest,
            date.timeIntervalSince1970, date.timeIntervalSince1970,
          ])
        if draft.kind == "session.stop", let sessionID = draft.sessionID {
          try Self.closeWorkbenchGeneration(
            sessionID: sessionID, generation: generation,
            at: date, in: db)
        }
        guard let operation = try Self.workbenchOperation(id: draft.operationID, in: db) else {
          throw ServiceStoreError.corruptRecord
        }
        return ServiceWorkbenchOperationRegistration(operation: operation, created: true)
      }
    } catch let error as ServiceStoreError { throw error } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func workbenchOperation(id: String) throws -> ServiceWorkbenchOperation? {
    try ServiceValidation.identifier(id, field: "operation.id", maximumBytes: 256)
    do {
      return try database.read { try Self.workbenchOperation(id: id, in: $0) }
    } catch let error as ServiceStoreError { throw error } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func workbenchOperations(
    ids: [String]? = nil, sessionID: String? = nil, unresolvedOnly: Bool = false, limit: Int = 100
  ) throws -> [ServiceWorkbenchOperation] {
    guard (1...500).contains(limit), ids.map({ $0.count <= 500 }) ?? true else {
      throw ServiceStoreError.invalidArgument("operation.limit")
    }
    if let ids, ids.isEmpty { return [] }
    for id in ids ?? [] {
      try ServiceValidation.identifier(id, field: "operation.id", maximumBytes: 256)
    }
    if let sessionID {
      try ServiceValidation.identifier(sessionID, field: "operation.sessionID", maximumBytes: 1_024)
    }
    do {
      return try database.read { db in
        var clauses: [String] = []
        var arguments = StatementArguments()
        if let ids {
          clauses.append(
            "operation_id IN (\(Array(repeating: "?", count: ids.count).joined(separator: ",")))")
          arguments += StatementArguments(ids)
        }
        if let sessionID {
          clauses.append("session_id = ?")
          arguments += [sessionID]
        }
        if unresolvedOnly {
          clauses.append("phase IN ('recorded', 'dispatching', 'accepted', 'unknown')")
        }
        let whereClause = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        arguments += [limit]
        return try Row.fetchAll(
          db,
          sql:
            "SELECT * FROM bridge_service_workbench_operations\(whereClause) ORDER BY updated_at, operation_id LIMIT ?",
          arguments: arguments
        ).map(Self.decodeWorkbenchOperation)
      }
    } catch let error as ServiceStoreError { throw error } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func transitionWorkbenchOperation(
    id: String, expectedVersion: Int64, phase: ServiceWorkbenchOperationPhase,
    resultTargetID: String? = nil, resultJSON: String? = nil,
    confirmedUndispatched: Bool = false, at date: Date = Date()
  ) throws -> ServiceWorkbenchOperation {
    try ServiceValidation.identifier(id, field: "operation.id", maximumBytes: 256)
    if let resultTargetID {
      try ServiceValidation.identifier(
        resultTargetID, field: "operation.resultTarget", maximumBytes: 1_024)
    }
    if let resultJSON {
      try Self.validateWorkbenchJSON(resultJSON, field: "operation.result", requireObject: false)
    }
    try ServiceValidation.date(date, field: "operation.date")
    do {
      return try database.write { db in
        guard let old = try Self.workbenchOperation(id: id, in: db) else {
          throw ServiceStoreError.invalidArgument("operation.notFound")
        }
        guard old.version == expectedVersion else {
          throw ServiceStoreError.invalidArgument("operation.versionConflict")
        }
        guard
          Self.allowedWorkbenchTransition(
            old.phase, phase, confirmedUndispatched: confirmedUndispatched),
          !(old.cancelled && (phase == .recorded || phase == .dispatching)),
          old.resultTargetID == nil || resultTargetID == nil || old.resultTargetID == resultTargetID
        else { throw ServiceStoreError.invalidArgument("operation.transition") }
        try db.execute(
          sql: """
            UPDATE bridge_service_workbench_operations SET phase = ?,
              result_target_id = COALESCE(result_target_id, ?), result_json = COALESCE(?, result_json),
              cancelled = CASE WHEN ? = 'cancelled' THEN 1 ELSE cancelled END,
              version = version + 1, updated_at = ? WHERE operation_id = ? AND version = ?
            """,
          arguments: [
            phase.rawValue, resultTargetID, resultJSON, phase.rawValue, date.timeIntervalSince1970,
            id,
            expectedVersion,
          ])
        guard let result = try Self.workbenchOperation(id: id, in: db) else {
          throw ServiceStoreError.corruptRecord
        }
        return result
      }
    } catch let error as ServiceStoreError { throw error } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func cancelWorkbenchOperation(
    id: String, closesGeneration: Bool = false,
    at date: Date = Date()
  ) throws
    -> ServiceWorkbenchOperation
  {
    try ServiceValidation.identifier(id, field: "operation.id", maximumBytes: 256)
    try ServiceValidation.date(date, field: "operation.date")
    do {
      return try database.write { db in
        guard let old = try Self.workbenchOperation(id: id, in: db) else {
          throw ServiceStoreError.invalidArgument("operation.notFound")
        }
        if old.phase.isTerminal { return old }
        if closesGeneration, let sessionID = old.draft.sessionID {
          try Self.closeWorkbenchGeneration(
            sessionID: sessionID, generation: old.generation,
            at: date, in: db)
        }
        let current = try Self.workbenchOperation(id: id, in: db) ?? old
        if current.cancelled { return current }
        try db.execute(
          sql: """
            UPDATE bridge_service_workbench_operations SET cancelled = 1,
              phase = CASE WHEN phase = 'recorded' THEN 'cancelled' ELSE phase END,
              version = version + 1, updated_at = ? WHERE operation_id = ?
            """, arguments: [date.timeIntervalSince1970, id])
        guard let result = try Self.workbenchOperation(id: id, in: db) else {
          throw ServiceStoreError.corruptRecord
        }
        return result
      }
    } catch let error as ServiceStoreError { throw error } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  static func workbenchOperation(id: String, in db: Database) throws -> ServiceWorkbenchOperation? {
    try Row.fetchOne(
      db, sql: "SELECT * FROM bridge_service_workbench_operations WHERE operation_id = ?",
      arguments: [id]
    )
    .map(Self.decodeWorkbenchOperation)
  }

  private static func decodeWorkbenchOperation(_ row: Row) throws -> ServiceWorkbenchOperation {
    guard let phase = ServiceWorkbenchOperationPhase(rawValue: row["phase"]) else {
      throw ServiceStoreError.corruptRecord
    }
    let draft = ServiceWorkbenchOperationDraft(
      operationID: row["operation_id"], kind: row["kind"], sessionID: row["session_id"],
      childID: row["child_id"], projectID: row["project_id"], targetID: row["target_id"],
      requestID: row["request_id"], inputJSON: row["input_json"])
    return ServiceWorkbenchOperation(
      draft: draft, generation: row["generation"], inputDigest: row["input_digest"], phase: phase,
      resultTargetID: row["result_target_id"], resultJSON: row["result_json"],
      cancelled: (row["cancelled"] as Int) != 0, version: row["version"],
      createdAt: Date(timeIntervalSince1970: row["created_at"]),
      updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
  }

  private static func allowedWorkbenchTransition(
    _ old: ServiceWorkbenchOperationPhase, _ new: ServiceWorkbenchOperationPhase,
    confirmedUndispatched: Bool
  ) -> Bool {
    if old == new { return !old.isTerminal }
    switch old {
    case .recorded: return [.dispatching, .failed, .cancelled].contains(new)
    case .dispatching:
      return [.accepted, .unknown, .failed, .cancelled].contains(new)
        || (new == .recorded && confirmedUndispatched)
    case .accepted: return [.unknown, .completed, .failed, .cancelled].contains(new)
    case .unknown:
      return [.accepted, .completed, .failed, .cancelled].contains(new)
        || (new == .recorded && confirmedUndispatched)
    case .completed, .failed, .cancelled: return false
    }
  }

  private static func validateWorkbenchDraft(_ draft: ServiceWorkbenchOperationDraft) throws {
    try ServiceValidation.identifier(draft.operationID, field: "operation.id", maximumBytes: 256)
    try ServiceValidation.identifier(draft.kind, field: "operation.kind", maximumBytes: 128)
    try ServiceValidation.identifier(
      draft.requestID, field: "operation.requestID", maximumBytes: 256)
    for value in [draft.sessionID, draft.childID, draft.projectID, draft.targetID].compactMap({ $0 }
    ) {
      try ServiceValidation.identifier(value, field: "operation.binding", maximumBytes: 1_024)
    }
    try validateWorkbenchJSON(draft.inputJSON, field: "operation.input", requireObject: true)
  }

  private static func validateWorkbenchJSON(_ json: String, field: String, requireObject: Bool)
    throws
  {
    guard json.utf8.count <= 2 * 1_024 * 1_024,
      let value = try? JSONSerialization.jsonObject(
        with: Data(json.utf8), options: [.fragmentsAllowed]),
      !requireObject || value is [String: Any]
    else { throw ServiceStoreError.invalidArgument(field) }
  }
}
