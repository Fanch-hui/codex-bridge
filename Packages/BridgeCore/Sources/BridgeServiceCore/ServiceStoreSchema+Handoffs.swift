import GRDB

extension ServiceStoreSchema {
  static func createVersionEighteen(in db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE bridge_service_handoffs (
          handoff_id TEXT PRIMARY KEY NOT NULL,
          project_id TEXT NOT NULL,
          source_task_id TEXT NOT NULL,
          target_task_id TEXT UNIQUE,
          target_fingerprint TEXT NOT NULL,
          packet_json BLOB NOT NULL,
          preview_json BLOB NOT NULL,
          created_at REAL NOT NULL,
          FOREIGN KEY (project_id) REFERENCES bridge_service_projects(project_id) ON DELETE CASCADE,
          CHECK (length(CAST(handoff_id AS BLOB)) BETWEEN 1 AND 128),
          CHECK (length(CAST(packet_json AS BLOB)) BETWEEN 2 AND 1048576),
          CHECK (length(CAST(preview_json AS BLOB)) BETWEEN 2 AND 196608),
          CHECK (length(target_fingerprint) = 64)
        ) WITHOUT ROWID;
        CREATE INDEX bridge_service_handoffs_source ON bridge_service_handoffs(source_task_id);
        UPDATE bridge_service_meta SET schema_version = 18 WHERE singleton = 1;
        """)
  }
}
