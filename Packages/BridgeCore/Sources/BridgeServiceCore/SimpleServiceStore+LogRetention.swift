import Foundation
import GRDB

extension SimpleServiceStore {
  @discardableResult
  public func pruneTaskEventLogs(at now: Date = Date()) throws -> Int {
    try ServiceValidation.date(now, field: "taskEvents.retentionDate")
    let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
    do {
      return try database.write { db in
        try db.execute(
          sql: "DELETE FROM bridge_service_task_events WHERE created_at < ?",
          arguments: [cutoff.timeIntervalSince1970]
        )
        return db.changesCount
      }
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }
}

extension ServiceStoreSchema {
  static func ensureTaskEventRetentionIndex(_ database: DatabaseQueue) throws {
    try database.write { db in
      try db.execute(
        sql: """
          CREATE INDEX IF NOT EXISTS bridge_service_task_events_created
          ON bridge_service_task_events(created_at)
          """
      )
    }
  }
}
