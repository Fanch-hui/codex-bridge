import GRDB

extension ServiceStoreSchema {
  /// Adds the durable queue marker without rebuilding the task history tables.
  static func createVersionSeventeen(in db: Database) throws {
    try db.execute(
      sql: """
        DROP INDEX IF EXISTS bridge_service_one_active_write_task;

        ALTER TABLE bridge_service_tasks
          ADD COLUMN queue_if_busy INTEGER NOT NULL DEFAULT 0
            CHECK (queue_if_busy IN (0, 1));

        ALTER TABLE bridge_service_tasks
          ADD COLUMN queue_state TEXT NOT NULL DEFAULT 'active'
            CHECK (queue_state IN ('active', 'queued'));

        CREATE TABLE bridge_service_task_queue (
            task_id TEXT PRIMARY KEY NOT NULL,
            enqueued_at REAL NOT NULL,
            FOREIGN KEY (task_id)
              REFERENCES bridge_service_tasks(task_id) ON DELETE CASCADE,
            CHECK (length(CAST(task_id AS BLOB)) BETWEEN 1 AND 128)
        ) WITHOUT ROWID;

        CREATE INDEX bridge_service_task_queue_project_order
        ON bridge_service_task_queue(enqueued_at, task_id);

        CREATE UNIQUE INDEX bridge_service_one_active_write_task
        ON bridge_service_tasks(project_id)
        WHERE permission_mode = 'workspace-write'
          AND queue_state = 'active'
          AND status IN (
            'awaiting_local_approval', 'starting', 'running',
            'waiting_for_codex_approval', 'unknown'
          );

        UPDATE bridge_service_meta SET schema_version = 17 WHERE singleton = 1;
        """)
  }
}
