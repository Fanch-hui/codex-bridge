import GRDB

extension ServiceStoreSchema {
  static func createVersionTwentyOne(in db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE bridge_service_task_attachments (
          task_id TEXT NOT NULL,
          position INTEGER NOT NULL CHECK(position BETWEEN 0 AND 7),
          relative_path TEXT NOT NULL CHECK(length(CAST(relative_path AS BLOB)) BETWEEN 1 AND 2048),
          mime_type TEXT NOT NULL CHECK(mime_type IN ('image/png', 'image/jpeg', 'image/webp')),
          byte_count INTEGER NOT NULL CHECK(byte_count BETWEEN 1 AND 8388608),
          sha256 TEXT NOT NULL CHECK(length(sha256) = 64 AND sha256 NOT GLOB '*[^0-9a-f]*'),
          PRIMARY KEY(task_id, position),
          UNIQUE(task_id, relative_path),
          FOREIGN KEY (task_id)
            REFERENCES bridge_service_tasks(task_id) ON DELETE CASCADE,
          CHECK (length(CAST(task_id AS BLOB)) BETWEEN 1 AND 128)
        ) WITHOUT ROWID;
        UPDATE bridge_service_meta SET schema_version = 21 WHERE singleton = 1;
        """)
  }
}
