import GRDB

extension ServiceStoreSchema {
  static func createVersionTwentyFive(in db: Database) throws {
    try db.execute(
      sql: """
        DROP INDEX IF EXISTS bridge_service_one_active_write_task;
        ALTER TABLE bridge_service_tasks ADD COLUMN execution_group_id TEXT;

        CREATE TABLE bridge_service_execution_groups (
          project_id TEXT PRIMARY KEY NOT NULL
            REFERENCES bridge_service_projects(project_id) ON DELETE CASCADE,
          group_id TEXT UNIQUE NOT NULL,
          root_session_id TEXT UNIQUE,
          root_active INTEGER NOT NULL CHECK (root_active IN (0, 1)),
          root_closing INTEGER NOT NULL CHECK (root_closing IN (0, 1)),
          root_permission_mode TEXT CHECK (root_permission_mode IN ('read-only', 'full')),
          CHECK ((root_session_id IS NULL AND root_active = 0 AND root_closing = 0 AND root_permission_mode IS NULL)
            OR (root_session_id IS NOT NULL AND root_permission_mode IS NOT NULL))
        );

        UPDATE bridge_service_tasks
        SET execution_group_id = 'task:' || task_id
        WHERE permission_mode = 'workspace-write' AND queue_state = 'active'
          AND status IN ('awaiting_local_approval', 'starting', 'running',
                         'waiting_for_codex_approval', 'unknown');

        INSERT INTO bridge_service_execution_groups
          (project_id, group_id, root_session_id, root_active, root_closing, root_permission_mode)
        SELECT project_id, execution_group_id, NULL, 0, 0, NULL FROM bridge_service_tasks
        WHERE execution_group_id IS NOT NULL;

        CREATE INDEX bridge_service_task_execution_group
          ON bridge_service_tasks(execution_group_id, status, queue_state);

        CREATE TABLE bridge_service_embedded_dsh_subagents (
          parent_session_id TEXT NOT NULL,
          child_id TEXT NOT NULL,
          project_id TEXT NOT NULL REFERENCES bridge_service_projects(project_id) ON DELETE CASCADE,
          provider_id TEXT NOT NULL,
          installation_id TEXT,
          current_task_id TEXT REFERENCES bridge_service_tasks(task_id) ON DELETE SET NULL,
          current_request_id TEXT NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          PRIMARY KEY (parent_session_id, child_id)
        ) WITHOUT ROWID;

        CREATE TABLE bridge_service_embedded_dsh_inputs (
          parent_session_id TEXT NOT NULL,
          child_id TEXT NOT NULL,
          request_id TEXT NOT NULL,
          task_id TEXT UNIQUE REFERENCES bridge_service_tasks(task_id) ON DELETE SET NULL,
          result_delivered INTEGER NOT NULL DEFAULT 0 CHECK (result_delivered IN (0, 1)),
          PRIMARY KEY (parent_session_id, child_id, request_id),
          FOREIGN KEY (parent_session_id, child_id)
            REFERENCES bridge_service_embedded_dsh_subagents(parent_session_id, child_id)
            ON DELETE CASCADE
        ) WITHOUT ROWID;

        UPDATE bridge_service_meta SET schema_version = 25 WHERE singleton = 1;
        """)
  }
}
