import GRDB

extension ServiceStoreSchema {
  static func createVersionSixteen(in db: Database) throws {
    let tables = [
      "bridge_service_tasks", "bridge_service_task_events", "bridge_service_task_messages",
    ]
    var definitions: [String: String] = [:]
    var indexes: [String] = []
    for table in tables {
      guard
        var definition = try String.fetchOne(
          db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
          arguments: [table]
        )
      else { throw ServiceStoreError.corruptSchema }
      if table == "bridge_service_tasks" {
        let check =
          "CHECK (result_summary IS NULL OR length(CAST(result_summary AS BLOB)) <= 32768),"
        guard definition.contains(check) else { throw ServiceStoreError.corruptSchema }
        definition = definition.replacingOccurrences(of: check, with: "")
      } else if table == "bridge_service_task_messages" {
        let check = "CHECK (length(CAST(content AS BLOB)) BETWEEN 1 AND 262144)"
        guard definition.contains(check) else { throw ServiceStoreError.corruptSchema }
        definition = definition.replacingOccurrences(
          of: check, with: "CHECK (length(CAST(content AS BLOB)) >= 1)")
      }
      definitions[table] = definition
      indexes += try String.fetchAll(
        db,
        sql:
          "SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = ? AND sql IS NOT NULL",
        arguments: [table]
      )
      try db.execute(sql: "CREATE TEMP TABLE v16_\(table) AS SELECT * FROM \(table)")
    }
    for table in tables.reversed() {
      try db.execute(sql: "DROP TABLE \(table)")
    }
    for table in tables {
      guard let definition = definitions[table] else { throw ServiceStoreError.corruptSchema }
      try db.execute(sql: definition)
      try db.execute(sql: "INSERT INTO \(table) SELECT * FROM v16_\(table)")
      try db.execute(sql: "DROP TABLE v16_\(table)")
    }
    for index in indexes { try db.execute(sql: index) }
    guard try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
      throw ServiceStoreError.corruptSchema
    }
    try db.execute(sql: "UPDATE bridge_service_meta SET schema_version = 16 WHERE singleton = 1")
  }
}
