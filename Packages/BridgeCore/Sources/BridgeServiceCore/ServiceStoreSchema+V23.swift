import GRDB

extension ServiceStoreSchema {
  static func createVersionTwentyThree(in db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE bridge_service_agent_runtime_artifacts (
          installation_id TEXT PRIMARY KEY NOT NULL
            REFERENCES bridge_service_agent_installations(installation_id) ON DELETE CASCADE,
          artifacts_json BLOB NOT NULL CHECK (typeof(artifacts_json) = 'blob')
        );
        UPDATE bridge_service_meta SET schema_version = 23 WHERE singleton = 1;
        """)
  }
}
