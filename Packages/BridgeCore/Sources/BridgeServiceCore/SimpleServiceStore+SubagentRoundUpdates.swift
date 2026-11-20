import Foundation
import GRDB

public enum SubagentRoundUpdateOutcome: Equatable, Sendable {
  case updated(SubagentRound)
  /// The stored phase is not the expected one; nothing was written. Carries the stored row.
  case phaseMismatch(SubagentRound)
  case notFound
}

extension SimpleServiceStore {
  /// Compare-and-set on the phase. When the stored phase equals `expectedPhase`, applies `mutate`
  /// to the mutable fields, moves the round to `next` (default: stays in `expectedPhase`) and
  /// writes it in one transaction. Fields that only make sense in the old phase are dropped:
  /// the prompt outside `queued`/`dispatching`/`unknown`, `waitingReason` outside `queued` and
  /// `dispatchError` outside `unknown`. The result must satisfy `SubagentRound.validate`, so a
  /// move to `failed` has to set `failureOrigin` in `mutate`.
  public func updateSubagentRound(
    _ key: SubagentRoundKey, expectedPhase: SubagentRoundPhase,
    to next: SubagentRoundPhase? = nil, at date: Date = Date(),
    _ mutate: @Sendable (inout SubagentRound) throws -> Void = { _ in }
  ) throws -> SubagentRoundUpdateOutcome {
    try ServiceValidation.date(date, field: "subagentRound.date")
    let target = next ?? expectedPhase
    do {
      return try database.write { db in
        guard var round = try Self.subagentRound(key, in: db) else { return .notFound }
        guard round.phase == expectedPhase else { return .phaseMismatch(round) }
        guard expectedPhase.canTransition(to: target, kind: round.kind) else {
          throw ServiceStoreError.invalidArgument("subagentRound.transition")
        }
        try mutate(&round)
        round.phase = target
        if !target.holdsPrompt || round.isSteer { round.prompt = nil }
        if target != .queued { round.waitingReason = nil }
        if target != .unknown { round.dispatchError = nil }
        round.updatedAt = date
        try round.validate()
        return .updated(try Self.write(round, in: db))
      }
    } catch let error as ServiceStoreError { throw error } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  /// Records that the result (or failure notice) of a `settled` or `failed` round reached the
  /// controller. Idempotent. A round with a task also marks the matching
  /// `bridge_service_embedded_dsh_inputs` row delivered in the same transaction, so the older
  /// `pendingEmbeddedDSHResults` query never reports a result the ledger already delivered.
  public func markSubagentRoundDelivered(
    _ key: SubagentRoundKey, at date: Date = Date()
  ) throws -> SubagentRoundUpdateOutcome {
    try ServiceValidation.date(date, field: "subagentRound.date")
    do {
      return try database.write { db in
        guard var round = try Self.subagentRound(key, in: db) else { return .notFound }
        guard round.deliveryRequired, [.settled, .failed].contains(round.phase) else {
          return .phaseMismatch(round)
        }
        guard !round.delivered else { return .updated(round) }
        round.delivered = true
        round.updatedAt = date
        let stored = try Self.write(round, in: db)
        if let taskID = round.taskID {
          try db.execute(
            sql: """
              UPDATE bridge_service_embedded_dsh_inputs SET result_delivered = 1
              WHERE parent_session_id = ? AND child_id = ? AND request_id = ? AND task_id = ?
              """,
            arguments: [key.rootID, key.childID, key.requestID, taskID])
        }
        return .updated(stored)
      }
    } catch let error as ServiceStoreError { throw error } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  /// Writes the mutable fields and returns the row as stored, so the caller sees exactly what a
  /// later read returns (the time columns are rounded to a `Double`).
  private static func write(_ round: SubagentRound, in db: Database) throws -> SubagentRound {
    try db.execute(
      sql: """
        UPDATE \(SubagentRoundCodec.table) SET
          phase = ?, prompt = ?, task_id = ?, waiting_reason = ?, failure_reason = ?,
          failure_origin = ?, dispatch_error = ?, workspace_mode = ?, write_scope = ?,
          reservation_held = ?, lease_held = ?, delivered = ?, settled_at = ?, updated_at = ?
        WHERE root_id = ? AND child_id = ? AND request_id = ?
        """,
      arguments: [
        round.phase.rawValue, round.prompt, round.taskID, round.waitingReason,
        round.failureReason, round.failureOrigin?.rawValue, round.dispatchError,
        round.workspaceMode?.rawValue, round.writeScope?.rawValue, round.reservationHeld,
        round.leaseHeld, round.delivered, round.settledAt?.timeIntervalSince1970,
        round.updatedAt.timeIntervalSince1970, round.key.rootID, round.key.childID,
        round.key.requestID,
      ])
    guard db.changesCount == 1, let stored = try subagentRound(round.key, in: db) else {
      throw ServiceStoreError.corruptRecord
    }
    return stored
  }
}
