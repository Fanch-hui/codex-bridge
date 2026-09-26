import GRDB

extension ServiceStoreSchema {
  static func createVersionTwenty(in db: Database) throws {
    try db.execute(
      sql: "ALTER TABLE bridge_service_task_events RENAME TO bridge_service_task_events_v19")
    try db.execute(
      sql: """
        CREATE TABLE bridge_service_task_events (
          event_id INTEGER PRIMARY KEY AUTOINCREMENT,
          task_id TEXT NOT NULL,
          kind TEXT NOT NULL CHECK (kind IN (
            'task.created', 'task.approved', 'execution.starting', 'execution.started',
            'execution.plan_updated', 'execution.command_completed', 'execution.file_changed',
            'approval.requested', 'approval.resolved', 'user_input.requested',
            'user_input.resolved', 'supervisor.started', 'supervisor.decision',
            'supervisor.degraded', 'execution.turn_completed', 'task.completed',
            'task.failed', 'task.interrupted', 'task.marked_unknown'
          )),
          summary TEXT NOT NULL,
          details TEXT,
          created_at REAL NOT NULL,
          FOREIGN KEY (task_id) REFERENCES bridge_service_tasks(task_id) ON DELETE CASCADE,
          CHECK (length(CAST(task_id AS BLOB)) BETWEEN 1 AND 128),
          CHECK (length(CAST(summary AS BLOB)) BETWEEN 1 AND 8192),
          CHECK (details IS NULL OR length(CAST(details AS BLOB)) <= 65536)
        );

        INSERT INTO bridge_service_task_events (event_id, task_id, kind, summary, created_at)
        SELECT event_id, task_id, kind, summary, created_at FROM bridge_service_task_events_v19;

        DROP TABLE bridge_service_task_events_v19;
        CREATE INDEX bridge_service_task_events_task
          ON bridge_service_task_events(task_id, event_id DESC);
        UPDATE bridge_service_meta SET schema_version = 20 WHERE singleton = 1;
        """)
  }
}
