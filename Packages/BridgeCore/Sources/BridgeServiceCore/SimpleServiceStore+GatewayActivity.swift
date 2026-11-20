import Foundation
import GRDB

extension ServiceStoreSchema {
  static func createGatewayActivity(in db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE bridge_service_gateway_activity (
          byte_offset INTEGER PRIMARY KEY, recorded_at REAL NOT NULL, entry TEXT NOT NULL
        );
        CREATE INDEX bridge_service_gateway_activity_date ON bridge_service_gateway_activity(recorded_at);
        INSERT INTO bridge_service_gateway_activity(byte_offset, recorded_at, entry)
          SELECT COALESCE(SUM(length(CAST(value AS BLOB))) OVER (
            ORDER BY key ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0),
            strftime('%s', json_extract(value, '$.date')), value
          FROM json_each((SELECT setting_value FROM bridge_service_settings WHERE setting_key='gateway.activity'));
        DELETE FROM bridge_service_settings WHERE setting_key='gateway.activity';
        UPDATE bridge_service_meta SET schema_version=29 WHERE singleton=1;
        """)
  }
}

extension SimpleServiceStore {
  public func appendGatewayActivity(_ entry: String, at date: Date = Date()) throws {
    let size = entry.utf8.count
    guard size > 0, size <= 65536 else {
      throw ServiceStoreError.invalidArgument("gateway.activity")
    }
    try database.write { db in
      // Byte offsets let size-based eviction use the primary key even for long histories.
      let offset =
        try Int64.fetchOne(
          db,
          sql: """
            SELECT byte_offset + length(CAST(entry AS BLOB)) FROM bridge_service_gateway_activity
            ORDER BY byte_offset DESC LIMIT 1
            """) ?? 0
      try db.execute(
        sql: "INSERT INTO bridge_service_gateway_activity VALUES (?, ?, ?)",
        arguments: [offset, date.timeIntervalSince1970, entry])
      try db.execute(
        sql: "DELETE FROM bridge_service_gateway_activity WHERE byte_offset < ? OR recorded_at < ?",
        arguments: [
          offset + Int64(size) - 100_000_000,
          date.addingTimeInterval(-7 * 86400).timeIntervalSince1970,
        ])
    }
  }

  public func recentGatewayActivity(at date: Date = Date()) throws -> [String] {
    try database.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT entry FROM bridge_service_gateway_activity WHERE recorded_at >= ?
          ORDER BY byte_offset DESC LIMIT 128
          """, arguments: [date.addingTimeInterval(-7 * 86400).timeIntervalSince1970])
    }
  }
}
