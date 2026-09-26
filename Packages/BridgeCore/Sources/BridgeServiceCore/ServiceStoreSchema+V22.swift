import GRDB

extension ServiceStoreSchema {
  static func createVersionTwentyTwo(in db: Database) throws {
    try db.execute(
      sql: """
        ALTER TABLE bridge_service_tasks
        ADD COLUMN selected_skills_json BLOB NOT NULL DEFAULT X'5B5D'
        CHECK (typeof(selected_skills_json) = 'blob'
          AND length(selected_skills_json) BETWEEN 2 AND 2097152);
        UPDATE bridge_service_meta SET schema_version = 22 WHERE singleton = 1;
        """
    )
  }
}
