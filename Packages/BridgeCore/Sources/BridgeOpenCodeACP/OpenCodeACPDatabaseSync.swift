import Foundation
import GRDB

#if os(macOS)
  import Darwin
#elseif os(Linux)
  import Glibc
#endif

enum OpenCodeACPDatabaseSync {
  private static let authTables = [
    "account",
    "account_state",
    "control_account",
    "credential",
  ]

  private struct TableSnapshot {
    let columns: [String]
    let rows: [[DatabaseValue]]
  }

  private struct NativeSnapshot {
    let schemaStatements: [String]
    let migration: TableSnapshot
    let auth: [String: TableSnapshot]
    let catalogKV: TableSnapshot?
  }

  static func synchronizeNativeAuthIfAvailable(
    dataHome: String,
    destinationDatabasePath: String,
    sourceEnvironment: [String: String]
  ) {
    guard
      let nativePath = resolveNativeDatabasePath(
        dataHome: dataHome,
        destinationDatabasePath: destinationDatabasePath,
        sourceEnvironment: sourceEnvironment
      ),
      let snapshot = try? readNativeSnapshot(at: nativePath)
    else {
      return
    }
    try? applySnapshot(snapshot, to: destinationDatabasePath)
  }

  private static func resolveNativeDatabasePath(
    dataHome: String,
    destinationDatabasePath: String,
    sourceEnvironment: [String: String]
  ) -> String? {
    var candidates = [
      URL(fileURLWithPath: dataHome, isDirectory: true)
        .appendingPathComponent("opencode", isDirectory: true)
        .appendingPathComponent("opencode.db").path
    ]
    #if os(Windows)
      let localAppData =
        sourceEnvironment["LOCALAPPDATA"]
        ?? sourceEnvironment.first {
          $0.key.caseInsensitiveCompare("LOCALAPPDATA") == .orderedSame
        }?.value
      if let localAppData, !localAppData.isEmpty, !localAppData.contains("\0") {
        candidates.append(
          URL(fileURLWithPath: localAppData, isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("opencode.db").path
        )
      }
    #endif
    let destinationCanonical = URL(fileURLWithPath: destinationDatabasePath)
      .resolvingSymlinksInPath().standardizedFileURL.path
    for candidate in candidates {
      let url = URL(fileURLWithPath: candidate)
      guard
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
        values.isRegularFile == true,
        values.isSymbolicLink != true
      else {
        continue
      }
      let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
      if canonical != destinationCanonical {
        return candidate
      }
    }
    return nil
  }

  private static func readNativeSnapshot(at path: String) throws -> NativeSnapshot? {
    var config = Configuration()
    config.readonly = true
    config.busyMode = .timeout(2)
    config.foreignKeysEnabled = false
    let queue = try DatabaseQueue(path: path, configuration: config)
    return try queue.read { db in
      let tables = Set(
        try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
      )
      guard
        tables.contains("migration"),
        !tables.isDisjoint(with: authTables)
      else {
        return nil
      }
      let schemaStatements = try String.fetchAll(
        db,
        sql: """
          SELECT sql FROM sqlite_master
          WHERE type IN ('table', 'index')
            AND sql IS NOT NULL
            AND name NOT LIKE 'sqlite_%'
            AND UPPER(LTRIM(sql)) NOT LIKE 'CREATE VIRTUAL TABLE%'
          ORDER BY CASE type WHEN 'table' THEN 0 ELSE 1 END, rowid ASC
          """
      )
      guard let migration = try fetchTableSnapshot(db, table: "migration") else {
        return nil
      }
      var auth: [String: TableSnapshot] = [:]
      for table in authTables where tables.contains(table) {
        if let snapshot = try fetchTableSnapshot(db, table: table) {
          auth[table] = snapshot
        }
      }
      let catalogKV: TableSnapshot?
      if tables.contains("kv") {
        catalogKV = try fetchTableSnapshot(
          db,
          table: "kv",
          whereClause: "\"key\" LIKE 'models-%' OR \"key\" LIKE 'migration.%'"
        )
      } else {
        catalogKV = nil
      }
      return NativeSnapshot(
        schemaStatements: schemaStatements,
        migration: migration,
        auth: auth,
        catalogKV: catalogKV
      )
    }
  }

  private static func applySnapshot(_ snapshot: NativeSnapshot, to destinationPath: String) throws {
    var config = Configuration()
    config.busyMode = .timeout(5)
    config.foreignKeysEnabled = false
    let queue = try DatabaseQueue(path: destinationPath, configuration: config)
    try queue.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA foreign_keys = OFF")
      try db.inTransaction(.immediate) {
        var destTables = Set(
          try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        )
        if !destTables.contains("migration") {
          for statement in snapshot.schemaStatements {
            try db.execute(sql: statement)
          }
          destTables = Set(
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
          )
          if destTables.contains("migration") {
            try replaceRows(db, table: "migration", snapshot: snapshot.migration, clearTable: true)
          }
        }
        for table in authTables where destTables.contains(table) {
          if let tableSnapshot = snapshot.auth[table] {
            try replaceRows(db, table: table, snapshot: tableSnapshot, clearTable: true)
          }
        }
        if destTables.contains("kv"), let kvSnapshot = snapshot.catalogKV {
          try replaceRows(db, table: "kv", snapshot: kvSnapshot, clearTable: false)
        }
        return .commit
      }
      try db.execute(sql: "PRAGMA foreign_keys = ON")
    }
    #if !os(Windows)
      if FileManager.default.fileExists(atPath: destinationPath) {
        _ = chmod(destinationPath, 0o600)
      }
    #endif
  }

  private static func fetchTableSnapshot(
    _ db: Database,
    table: String,
    whereClause: String? = nil
  ) throws -> TableSnapshot? {
    let columns = try tableColumns(db, table: table)
    guard !columns.isEmpty else { return nil }
    let quotedColumns = columns.map(quoteIdentifier).joined(separator: ", ")
    var sql = "SELECT \(quotedColumns) FROM \(quoteIdentifier(table))"
    if let whereClause {
      sql += " WHERE \(whereClause)"
    }
    let rows = try Row.fetchAll(db, sql: sql).map { row in
      Array(row.databaseValues)
    }
    return TableSnapshot(columns: columns, rows: rows)
  }

  private static func replaceRows(
    _ db: Database,
    table: String,
    snapshot: TableSnapshot,
    clearTable: Bool
  ) throws {
    let destColumnSet = Set(try tableColumns(db, table: table))
    let indices = snapshot.columns.enumerated().compactMap { index, name in
      destColumnSet.contains(name) ? index : nil
    }
    guard !indices.isEmpty else { return }
    let quotedTable = quoteIdentifier(table)
    if clearTable {
      try db.execute(sql: "DELETE FROM \(quotedTable)")
    }
    guard !snapshot.rows.isEmpty else { return }
    let commonColumns = indices.map { quoteIdentifier(snapshot.columns[$0]) }
      .joined(separator: ", ")
    let placeholders = Array(repeating: "?", count: indices.count).joined(separator: ", ")
    let verb = clearTable ? "INSERT" : "INSERT OR REPLACE"
    let sql = "\(verb) INTO \(quotedTable) (\(commonColumns)) VALUES (\(placeholders))"
    for row in snapshot.rows {
      let values = indices.map { row[$0] }
      try db.execute(sql: sql, arguments: StatementArguments(values))
    }
  }

  private static func tableColumns(_ db: Database, table: String) throws -> [String] {
    try Row.fetchAll(db, sql: "PRAGMA table_info(\(quoteIdentifier(table)))").compactMap {
      $0["name"] as String?
    }
  }

  private static func quoteIdentifier(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}
