import GRDB

extension ServiceStoreSchema {
  /// Round ledger for connected subagents. Not referenced by any existing table: a queued first
  /// round has no row in `bridge_service_embedded_dsh_subagents` yet, and `task_id` has no foreign
  /// key so tasks stay removable on their own.
  static func createVersionTwentySeven(in db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE bridge_service_subagent_rounds (
          root_id TEXT NOT NULL CHECK(length(CAST(root_id AS BLOB)) BETWEEN 1 AND 1024),
          child_id TEXT NOT NULL CHECK(length(CAST(child_id AS BLOB)) BETWEEN 1 AND 1024),
          request_id TEXT NOT NULL CHECK(length(CAST(request_id AS BLOB)) BETWEEN 1 AND 1024),
          project_id TEXT NOT NULL REFERENCES bridge_service_projects(project_id) ON DELETE CASCADE,
          ordinal INTEGER NOT NULL CHECK(ordinal >= 1),
          parent_session_id TEXT NOT NULL
            CHECK(length(CAST(parent_session_id AS BLOB)) BETWEEN 1 AND 1024),
          installation_id TEXT NOT NULL
            CHECK(length(CAST(installation_id AS BLOB)) BETWEEN 1 AND 1024),
          kind TEXT NOT NULL CHECK(kind IN ('start', 'send', 'steer')),
          phase TEXT NOT NULL CHECK(phase IN
            ('queued', 'dispatching', 'unknown', 'delivery_unknown', 'running', 'attached',
             'settled', 'cancelled', 'failed')),
          fingerprint TEXT NOT NULL CHECK(length(CAST(fingerprint AS BLOB)) BETWEEN 1 AND 128),
          prompt TEXT CHECK(prompt IS NULL OR length(CAST(prompt AS BLOB)) BETWEEN 1 AND 32768),
          options_json TEXT NOT NULL CHECK(length(CAST(options_json AS BLOB)) <= 65536),
          access TEXT CHECK(access IS NULL OR access = 'read-only'),
          repair_conflict INTEGER NOT NULL CHECK(repair_conflict IN (0, 1)),
          dependencies_json TEXT NOT NULL CHECK(length(CAST(dependencies_json AS BLOB)) <= 65536),
          previous_request_id TEXT CHECK(previous_request_id IS NULL
            OR length(CAST(previous_request_id AS BLOB)) BETWEEN 1 AND 1024),
          previous_task_id TEXT CHECK(previous_task_id IS NULL
            OR length(CAST(previous_task_id AS BLOB)) BETWEEN 1 AND 128),
          previous_run_id TEXT CHECK(previous_run_id IS NULL
            OR length(CAST(previous_run_id AS BLOB)) BETWEEN 1 AND 1024),
          requested_after_terminal INTEGER NOT NULL CHECK(requested_after_terminal IN (0, 1)),
          task_id TEXT CHECK(task_id IS NULL OR length(CAST(task_id AS BLOB)) BETWEEN 1 AND 128),
          waiting_reason TEXT CHECK(waiting_reason IS NULL
            OR length(CAST(waiting_reason AS BLOB)) BETWEEN 1 AND 64),
          failure_reason TEXT CHECK(failure_reason IS NULL
            OR length(CAST(failure_reason AS BLOB)) <= 8192),
          failure_origin TEXT CHECK(failure_origin IS NULL
            OR failure_origin IN ('dependency', 'dispatch', 'input')),
          dispatch_error TEXT CHECK(dispatch_error IS NULL
            OR length(CAST(dispatch_error AS BLOB)) <= 2048),
          delivery_required INTEGER NOT NULL CHECK(delivery_required IN (0, 1)),
          delivered INTEGER NOT NULL CHECK(delivered IN (0, 1)),
          workspace_mode TEXT CHECK(workspace_mode IS NULL
            OR workspace_mode IN ('read-only', 'shared', 'isolated')),
          write_scope TEXT CHECK(write_scope IS NULL OR write_scope IN ('task', 'tool')),
          reservation_held INTEGER NOT NULL CHECK(reservation_held IN (0, 1)),
          lease_held INTEGER NOT NULL CHECK(lease_held IN (0, 1)),
          child_created_at REAL NOT NULL,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          settled_at REAL,
          PRIMARY KEY (root_id, child_id, request_id),
          CHECK(delivered = 0 OR delivery_required = 1)
        ) WITHOUT ROWID;
        CREATE UNIQUE INDEX bridge_service_subagent_rounds_ordinal
          ON bridge_service_subagent_rounds(ordinal);
        CREATE INDEX bridge_service_subagent_rounds_child
          ON bridge_service_subagent_rounds(root_id, child_id, ordinal);
        CREATE INDEX bridge_service_subagent_rounds_project
          ON bridge_service_subagent_rounds(project_id);

        UPDATE bridge_service_meta SET schema_version = 27 WHERE singleton = 1;
        """)
  }
}
