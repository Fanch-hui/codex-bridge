import GRDB

extension ServiceStoreSchema {
  static func createVersionTwentySix(in db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE bridge_service_workbench_operations (
          operation_id TEXT PRIMARY KEY NOT NULL,
          kind TEXT NOT NULL,
          session_id TEXT,
          child_id TEXT,
          project_id TEXT,
          target_id TEXT,
          request_id TEXT NOT NULL,
          generation INTEGER NOT NULL CHECK(generation >= 0),
          input_json TEXT NOT NULL,
          input_digest TEXT NOT NULL,
          phase TEXT NOT NULL CHECK(phase IN
            ('recorded', 'dispatching', 'accepted', 'unknown', 'completed', 'failed', 'cancelled')),
          result_target_id TEXT,
          result_json TEXT,
          cancelled INTEGER NOT NULL CHECK(cancelled IN (0, 1)),
          version INTEGER NOT NULL CHECK(version >= 1),
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        );
        CREATE INDEX bridge_service_workbench_operations_session
          ON bridge_service_workbench_operations(session_id, updated_at, operation_id);
        CREATE INDEX bridge_service_workbench_operations_recovery
          ON bridge_service_workbench_operations(phase, updated_at, operation_id);

        CREATE TABLE bridge_service_workbench_generations (
          session_id TEXT PRIMARY KEY NOT NULL,
          generation INTEGER NOT NULL CHECK(generation >= 0),
          closed INTEGER NOT NULL CHECK(closed IN (0, 1))
        );

        CREATE TABLE bridge_service_workbench_conversations (
          logical_session_id TEXT PRIMARY KEY NOT NULL,
          native_session_id TEXT UNIQUE NOT NULL,
          project_id TEXT,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        );
        CREATE INDEX bridge_service_workbench_conversations_updated
          ON bridge_service_workbench_conversations(updated_at DESC, logical_session_id);
        CREATE TABLE bridge_service_workbench_segments (
          logical_session_id TEXT NOT NULL REFERENCES bridge_service_workbench_conversations(logical_session_id)
            ON DELETE CASCADE,
          native_session_id TEXT UNIQUE NOT NULL,
          ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
          project_id TEXT,
          created_at REAL NOT NULL,
          PRIMARY KEY(logical_session_id, ordinal)
        ) WITHOUT ROWID;

        CREATE TABLE bridge_service_workbench_bindings (
          logical_session_id TEXT PRIMARY KEY NOT NULL
            REFERENCES bridge_service_workbench_conversations(logical_session_id) ON DELETE CASCADE,
          source_native_session_id TEXT NOT NULL,
          target_native_session_id TEXT UNIQUE NOT NULL,
          project_id TEXT NOT NULL,
          request_id TEXT NOT NULL,
          tool_call_id TEXT NOT NULL,
          boundary_seq INTEGER CHECK(boundary_seq >= -1),
          phase TEXT NOT NULL CHECK(phase IN
            ('prepared', 'oldStopped', 'segmentCreated', 'continuationEnqueued', 'committed', 'cancelled')),
          version INTEGER NOT NULL CHECK(version >= 1),
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        );

        CREATE TABLE bridge_service_workbench_pending_interactions (
          logical_session_id TEXT NOT NULL,
          interaction_id TEXT NOT NULL,
          native_session_id TEXT NOT NULL,
          kind TEXT NOT NULL,
          event_seq INTEGER NOT NULL CHECK(event_seq >= 0),
          updated_at REAL NOT NULL,
          PRIMARY KEY(logical_session_id, interaction_id)
        ) WITHOUT ROWID;
        CREATE INDEX bridge_service_workbench_pending_recent
          ON bridge_service_workbench_pending_interactions(updated_at DESC);

        UPDATE bridge_service_meta SET schema_version = 26 WHERE singleton = 1;
        """)
  }
}
