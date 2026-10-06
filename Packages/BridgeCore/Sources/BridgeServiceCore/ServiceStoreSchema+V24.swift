import GRDB

extension ServiceStoreSchema {
  static func createVersionTwentyFour(in db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE bridge_service_dsh_task_bindings (
          task_id TEXT PRIMARY KEY NOT NULL REFERENCES bridge_service_tasks(task_id) ON DELETE CASCADE,
          connection_mode TEXT NOT NULL CHECK(connection_mode IN ('acp', 'native-desktop')),
          profile_id TEXT,
          request_id TEXT NOT NULL CHECK(length(request_id) BETWEEN 1 AND 256),
          CHECK(connection_mode = 'acp' OR profile_id IS NOT NULL)
        );
        CREATE TABLE bridge_service_dsh_native_sessions (
          installation_id TEXT NOT NULL REFERENCES bridge_service_agent_installations(installation_id) ON DELETE CASCADE,
          profile_id TEXT NOT NULL,
          project_id TEXT NOT NULL REFERENCES bridge_service_projects(project_id) ON DELETE CASCADE,
          session_id TEXT NOT NULL,
          PRIMARY KEY(installation_id, profile_id, project_id, session_id)
        );
        UPDATE bridge_service_meta SET schema_version = 24 WHERE singleton = 1;
        """)
  }
}
