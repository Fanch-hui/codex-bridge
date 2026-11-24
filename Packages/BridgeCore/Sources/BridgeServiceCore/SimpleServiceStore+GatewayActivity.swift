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

  /// Per provider and model totals over the retained window, newest models first.
  public func gatewayActivitySummary(at date: Date = Date()) throws -> [GatewayActivitySummary] {
    try database.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT json_extract(entry, '$.providerID') AS provider,
            json_extract(entry, '$.model') AS model,
            COUNT(*) AS requests,
            SUM(json_extract(entry, '$.state') = 'failed') AS failed,
            SUM(json_extract(entry, '$.usage.inputTokens') IS NOT NULL) AS measured,
            COALESCE(SUM(json_extract(entry, '$.usage.inputTokens')), 0) AS input,
            COALESCE(SUM(json_extract(entry, '$.usage.outputTokens')), 0) AS output,
            COALESCE(SUM(json_extract(entry, '$.usage.reasoningTokens')), 0) AS reasoning,
            COALESCE(SUM(CASE WHEN json_extract(entry, '$.usage.cacheReadTokens') IS NOT NULL
              THEN json_extract(entry, '$.usage.inputTokens') END), 0) AS cacheableInput,
            COALESCE(SUM(json_extract(entry, '$.usage.cacheReadTokens')), 0) AS cacheRead,
            MAX(recorded_at) AS latest
          FROM bridge_service_gateway_activity WHERE recorded_at >= ?
          GROUP BY provider, model ORDER BY latest DESC LIMIT 64
          """, arguments: [date.addingTimeInterval(-7 * 86400).timeIntervalSince1970]
      ).map { row in
        GatewayActivitySummary(
          providerID: row["provider"] ?? "", model: row["model"] ?? "",
          requests: row["requests"], failed: row["failed"], measured: row["measured"],
          inputTokens: row["input"], outputTokens: row["output"],
          reasoningTokens: row["reasoning"], cacheableInputTokens: row["cacheableInput"],
          cacheReadTokens: row["cacheRead"])
      }
    }
  }
}

public struct GatewayActivitySummary: Sendable, Equatable {
  public let providerID: String
  public let model: String
  public let requests: Int
  public let failed: Int
  /// Requests whose provider reported token counts.
  public let measured: Int
  public let inputTokens: Int
  public let outputTokens: Int
  public let reasoningTokens: Int
  /// Input tokens of requests that reported a cache read count, the base of the hit rate.
  public let cacheableInputTokens: Int
  public let cacheReadTokens: Int
}
