import GRDB

extension ServiceStoreSchema {
  static func createVersionTwentyEight(in db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE bridge_service_execution_roots (
          group_id TEXT NOT NULL REFERENCES bridge_service_execution_groups(group_id) ON DELETE CASCADE,
          root_session_id TEXT PRIMARY KEY NOT NULL,
          root_active INTEGER NOT NULL CHECK(root_active IN (0, 1)),
          root_closing INTEGER NOT NULL CHECK(root_closing IN (0, 1)),
          root_permission_mode TEXT NOT NULL CHECK(root_permission_mode IN ('read-only', 'full'))
        );
        CREATE INDEX bridge_service_execution_roots_group ON bridge_service_execution_roots(group_id);
        INSERT INTO bridge_service_execution_roots
          SELECT group_id, root_session_id, root_active, root_closing, root_permission_mode
          FROM bridge_service_execution_groups WHERE root_session_id IS NOT NULL;
        UPDATE bridge_service_execution_groups
          SET root_session_id = NULL, root_active = 0, root_closing = 0, root_permission_mode = NULL;
        UPDATE bridge_service_meta SET schema_version = 28 WHERE singleton = 1;
        """)
  }
}
