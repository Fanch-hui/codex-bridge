import GRDB

extension ServiceStoreSchema {
  static func createVersionNineteen(in db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE bridge_service_task_usage (
          task_id TEXT PRIMARY KEY NOT NULL REFERENCES bridge_service_tasks(task_id) ON DELETE CASCADE,
          snapshot BLOB NOT NULL CHECK(length(snapshot) <= 8192)
        ) WITHOUT ROWID;
        UPDATE bridge_service_meta SET schema_version = 19 WHERE singleton = 1;
        """)
  }
}
