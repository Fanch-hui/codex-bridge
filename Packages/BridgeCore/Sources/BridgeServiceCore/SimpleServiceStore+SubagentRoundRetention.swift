import Foundation
import GRDB

public struct SubagentRetirement: Equatable, Sendable {
  public let stamped: Int
  public let cleared: Int
  public let removed: Int
}

extension SimpleServiceStore {
  /// Applies `SubagentRoundRetention.plan` to one root in a single transaction: stamps newly
  /// finished rounds, clears stamps of rounds that are open again and deletes expired rounds.
  public func retireSubagentRounds(
    rootID: String, now: Date = Date(),
    isBusy: @Sendable (SubagentRound) -> Bool = { _ in false }
  ) throws -> SubagentRetirement {
    try ServiceValidation.identifier(rootID, field: "subagentRound.rootID", maximumBytes: 256)
    try ServiceValidation.date(now, field: "subagentRound.date")
    do {
      return try database.write { db in
        let rounds = try Row.fetchAll(
          db,
          sql: "SELECT * FROM \(SubagentRoundCodec.table) WHERE root_id = ? ORDER BY ordinal",
          arguments: [rootID]
        ).map(SubagentRoundCodec.decode)
        let plan = SubagentRoundRetention.plan(rounds: rounds, now: now, isBusy: isBusy)
        try Self.setSettleTime(plan.stamp, to: now, in: db)
        try Self.setSettleTime(plan.clear, to: nil, in: db)
        for key in plan.remove {
          try db.execute(
            sql: """
              DELETE FROM \(SubagentRoundCodec.table)
              WHERE root_id = ? AND child_id = ? AND request_id = ?
              """,
            arguments: [key.rootID, key.childID, key.requestID])
        }
        return SubagentRetirement(
          stamped: plan.stamp.count, cleared: plan.clear.count, removed: plan.remove.count)
      }
    } catch let error as ServiceStoreError { throw error } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  private static func setSettleTime(
    _ keys: [SubagentRoundKey], to date: Date?, in db: Database
  ) throws {
    for key in keys {
      try db.execute(
        sql: """
          UPDATE \(SubagentRoundCodec.table) SET settled_at = ?
          WHERE root_id = ? AND child_id = ? AND request_id = ?
          """,
        arguments: [date?.timeIntervalSince1970, key.rootID, key.childID, key.requestID])
    }
  }
}
