enum ServiceStoreV14Fixture {
  static let schema = #"""
    BEGIN TRANSACTION;
    CREATE TABLE bridge_service_agent_installation_artifacts (
        installation_id TEXT NOT NULL,
        role TEXT NOT NULL CHECK (role IN (
          'launch_configuration', 'runtime_manifest',
          'dependency_lock', 'node_interpreter'
        )),
        canonical_path TEXT NOT NULL,
        artifact_device TEXT NOT NULL,
        artifact_inode TEXT NOT NULL,
        artifact_size TEXT NOT NULL,
        artifact_mtime_ns INTEGER NOT NULL,
        artifact_sha256 TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        PRIMARY KEY (installation_id, role),
        FOREIGN KEY (installation_id)
          REFERENCES bridge_service_agent_installations(installation_id) ON DELETE CASCADE,
        CHECK (length(CAST(installation_id AS BLOB)) BETWEEN 1 AND 256),
        CHECK (length(CAST(canonical_path AS BLOB)) BETWEEN 1 AND 16384),
        CHECK (substr(canonical_path, 1, 1) = '/'),
        CHECK (length(artifact_device) BETWEEN 1 AND 20),
        CHECK (length(artifact_inode) BETWEEN 1 AND 20),
        CHECK (length(artifact_size) BETWEEN 1 AND 20),
        CHECK (artifact_mtime_ns >= 0),
        CHECK (length(artifact_sha256) = 64),
        CHECK (artifact_sha256 NOT GLOB '*[^0-9a-f]*'),
        CHECK (updated_at >= created_at)
    ) WITHOUT ROWID;
    CREATE TABLE bridge_service_agent_installations (
        installation_id TEXT PRIMARY KEY NOT NULL,
        provider_id TEXT NOT NULL,
        display_name TEXT NOT NULL,
        executable_path TEXT NOT NULL,
        canonical_executable_path TEXT NOT NULL,
        executable_device TEXT NOT NULL,
        executable_inode TEXT NOT NULL,
        executable_size TEXT NOT NULL,
        executable_mtime_ns INTEGER NOT NULL,
        executable_sha256 TEXT NOT NULL,
        version TEXT,
        protocol_revision TEXT,
        adapter_revision INTEGER NOT NULL,
        trust_profile TEXT NOT NULL
          CHECK (trust_profile IN ('managed', 'user_trusted')),
        security_profile_id TEXT,
        is_enabled INTEGER NOT NULL CHECK (is_enabled IN (0, 1)),
        availability TEXT NOT NULL
          CHECK (availability IN ('available', 'unavailable', 'needs_review')),
        capabilities_json BLOB NOT NULL,
        last_probe_error TEXT,
        last_probed_at REAL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        UNIQUE (provider_id, canonical_executable_path),
        CHECK (length(CAST(installation_id AS BLOB)) BETWEEN 1 AND 256),
        CHECK (length(CAST(provider_id AS BLOB)) BETWEEN 1 AND 128),
        CHECK (length(CAST(display_name AS BLOB)) BETWEEN 1 AND 256),
        CHECK (substr(executable_path, 1, 1) = '/'),
        CHECK (length(CAST(executable_path AS BLOB)) BETWEEN 1 AND 16384),
        CHECK (substr(canonical_executable_path, 1, 1) = '/'),
        CHECK (length(CAST(canonical_executable_path AS BLOB)) BETWEEN 1 AND 16384),
        CHECK (length(executable_device) BETWEEN 1 AND 20),
        CHECK (length(executable_inode) BETWEEN 1 AND 20),
        CHECK (length(executable_size) BETWEEN 1 AND 20),
        CHECK (executable_mtime_ns >= 0),
        CHECK (length(executable_sha256) = 64),
        CHECK (executable_sha256 NOT GLOB '*[^0-9a-f]*'),
        CHECK (version IS NULL OR length(CAST(version AS BLOB)) BETWEEN 1 AND 256),
        CHECK (
          protocol_revision IS NULL OR
          length(CAST(protocol_revision AS BLOB)) BETWEEN 1 AND 128
        ),
        CHECK (adapter_revision > 0),
        CHECK (
          security_profile_id IS NULL OR
          length(CAST(security_profile_id AS BLOB)) BETWEEN 1 AND 256
        ),
        CHECK (typeof(capabilities_json) = 'blob'),
        CHECK (length(capabilities_json) BETWEEN 2 AND 65536),
        CHECK (
          last_probe_error IS NULL OR
          length(CAST(last_probe_error AS BLOB)) BETWEEN 1 AND 4096
        ),
        CHECK (
          availability <> 'available' OR
          (version IS NOT NULL AND last_probed_at IS NOT NULL AND last_probe_error IS NULL)
        ),
        CHECK (last_probed_at IS NULL OR last_probed_at >= created_at),
        CHECK (updated_at >= created_at),
        CHECK (last_probed_at IS NULL OR last_probed_at <= updated_at)
    ) WITHOUT ROWID;
    CREATE TABLE bridge_service_meta (
        singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
        schema_version INTEGER NOT NULL CHECK (schema_version > 0)
    ) WITHOUT ROWID;
    INSERT INTO "bridge_service_meta" VALUES(1,14);
    CREATE TABLE bridge_service_projects (
        project_id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        canonical_path TEXT NOT NULL,
        root_device TEXT NOT NULL,
        root_inode TEXT NOT NULL,
        read_permission TEXT NOT NULL
          CHECK (read_permission IN ('denied', 'requiresLocalApproval', 'allowed')),
        write_permission TEXT NOT NULL
          CHECK (write_permission IN ('denied', 'requiresLocalApproval', 'allowed')),
        network_permission TEXT NOT NULL
          CHECK (network_permission IN ('denied', 'requiresLocalApproval', 'allowed')),
        direct_command_mode TEXT NOT NULL DEFAULT 'safe'
          CHECK (direct_command_mode IN ('denied', 'safe', 'full')),
        workspace_commands_json BLOB NOT NULL DEFAULT '[]',
        direct_blacklist_json BLOB NOT NULL DEFAULT '[]',
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL, root_volume_uuid TEXT
        CHECK (
          root_volume_uuid IS NULL OR
          length(CAST(root_volume_uuid AS BLOB)) BETWEEN 1 AND 256
        ),
        UNIQUE (canonical_path),
        UNIQUE (root_device, root_inode),
        CHECK (length(CAST(project_id AS BLOB)) BETWEEN 1 AND 128),
        CHECK (length(CAST(name AS BLOB)) BETWEEN 1 AND 1024),
        CHECK (substr(canonical_path, 1, 1) = '/'),
        CHECK (length(CAST(canonical_path AS BLOB)) BETWEEN 1 AND 16384),
        CHECK (length(root_device) BETWEEN 1 AND 20),
        CHECK (length(root_inode) BETWEEN 1 AND 20),
        CHECK (updated_at >= created_at)
    ) WITHOUT ROWID;
    CREATE TABLE bridge_service_settings (
        setting_key TEXT PRIMARY KEY NOT NULL,
        setting_value TEXT NOT NULL,
        updated_at REAL NOT NULL,
        CHECK (length(CAST(setting_key AS BLOB)) BETWEEN 1 AND 128),
        CHECK (length(CAST(setting_value AS BLOB)) <= 65536)
    ) WITHOUT ROWID;
    CREATE TABLE bridge_service_task_events (
        event_id INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id TEXT NOT NULL,
        kind TEXT NOT NULL CHECK (kind IN (
          'task.created', 'task.approved', 'execution.starting', 'execution.started',
          'execution.plan_updated', 'execution.command_completed', 'execution.file_changed',
          'approval.requested', 'approval.resolved', 'supervisor.started',
          'supervisor.decision', 'supervisor.degraded', 'execution.turn_completed',
          'task.completed', 'task.failed', 'task.interrupted', 'task.marked_unknown'
        )),
        summary TEXT NOT NULL,
        created_at REAL NOT NULL,
        FOREIGN KEY (task_id)
          REFERENCES bridge_service_tasks(task_id) ON DELETE CASCADE,
        CHECK (length(CAST(task_id AS BLOB)) BETWEEN 1 AND 128),
        CHECK (length(CAST(summary AS BLOB)) BETWEEN 1 AND 8192)
    );
    CREATE TABLE "bridge_service_task_messages" (
        message_id INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id TEXT NOT NULL,
        message_key TEXT NOT NULL,
        role TEXT NOT NULL CHECK (role IN ('user', 'agent')),
        content TEXT NOT NULL,
        created_at REAL NOT NULL,
        kind TEXT NOT NULL DEFAULT 'agent'
          CHECK (kind IN ('user', 'agent', 'reasoning', 'tool_call')),
        tool_name TEXT,
        tool_status TEXT CHECK (tool_status IN (
          'inProgress', 'completed', 'failed', 'declined', 'cancelled'
        )),
        tool_arguments TEXT,
        updated_at REAL NOT NULL DEFAULT 0,
        FOREIGN KEY (task_id)
          REFERENCES bridge_service_tasks(task_id) ON DELETE CASCADE,
        UNIQUE (task_id, message_key),
        CHECK (length(CAST(task_id AS BLOB)) BETWEEN 1 AND 128),
        CHECK (length(CAST(message_key AS BLOB)) BETWEEN 1 AND 256),
        CHECK (length(CAST(content AS BLOB)) BETWEEN 1 AND 262144)
    );
    CREATE TABLE "bridge_service_tasks" (
        task_id TEXT PRIMARY KEY NOT NULL,
        project_id TEXT NOT NULL,
        source TEXT NOT NULL CHECK (source IN (
          'chatgpt.mcp', 'mcp.client', 'macos.app', 'legacy.import'
        )),
        source_client_id TEXT NOT NULL DEFAULT '',
        client_request_id TEXT,
        prompt TEXT NOT NULL,
        requested_thread_id TEXT,
        codex_thread_id TEXT,
        codex_turn_id TEXT,
        status TEXT NOT NULL CHECK (status IN (
          'awaiting_local_approval', 'starting', 'running',
          'waiting_for_codex_approval', 'completed', 'failed', 'interrupted', 'unknown'
        )),
        supervisor_status TEXT NOT NULL CHECK (supervisor_status IN (
          'disabled', 'starting', 'running', 'degraded', 'completed'
        )),
        execution_model TEXT NOT NULL,
        execution_effort TEXT NOT NULL,
        supervisor_model TEXT,
        supervisor_effort TEXT,
        permission_mode TEXT NOT NULL
          CHECK (permission_mode IN ('read-only', 'workspace-write')),
        network_allowed INTEGER NOT NULL CHECK (network_allowed IN (0, 1)),
        access_mode TEXT NOT NULL DEFAULT 'request-approval'
          CHECK (access_mode IN ('request-approval', 'auto-review', 'full-access')),
        fast_mode INTEGER NOT NULL DEFAULT 0 CHECK (fast_mode IN (0, 1)),
        current_step TEXT,
        changed_files_json BLOB NOT NULL,
        result_summary TEXT,
        supervisor_summary TEXT,
        failure_code TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL, provider_id TEXT NOT NULL DEFAULT 'codex'
        CHECK (length(CAST(provider_id AS BLOB)) BETWEEN 1 AND 64), installation_id TEXT
        CHECK (installation_id IS NULL OR
          length(CAST(installation_id AS BLOB)) BETWEEN 1 AND 256), selection_mode TEXT NOT NULL DEFAULT 'legacy_codex'
        CHECK (selection_mode IN ('legacy_codex', 'explicit')), provider_session_id TEXT
        CHECK (provider_session_id IS NULL OR
          length(CAST(provider_session_id AS BLOB)) BETWEEN 1 AND 1024), provider_run_id TEXT
        CHECK (provider_run_id IS NULL OR
          length(CAST(provider_run_id AS BLOB)) BETWEEN 1 AND 1024),
        FOREIGN KEY (project_id)
          REFERENCES bridge_service_projects(project_id) ON DELETE RESTRICT,
        UNIQUE (source, source_client_id, client_request_id),
        CHECK (
          (source = 'mcp.client'
            AND length(CAST(source_client_id AS BLOB)) BETWEEN 1 AND 128)
          OR (source <> 'mcp.client' AND source_client_id = '')
        ),
        CHECK (length(CAST(task_id AS BLOB)) BETWEEN 1 AND 128),
        CHECK (length(CAST(project_id AS BLOB)) BETWEEN 1 AND 128),
        CHECK (client_request_id IS NULL OR
          length(CAST(client_request_id AS BLOB)) BETWEEN 1 AND 512),
        CHECK (length(CAST(prompt AS BLOB)) BETWEEN 1 AND 32768),
        CHECK (requested_thread_id IS NULL OR
          length(CAST(requested_thread_id AS BLOB)) BETWEEN 1 AND 1024),
        CHECK (codex_thread_id IS NULL OR
          length(CAST(codex_thread_id AS BLOB)) BETWEEN 1 AND 1024),
        CHECK (codex_turn_id IS NULL OR
          length(CAST(codex_turn_id AS BLOB)) BETWEEN 1 AND 1024),
        CHECK (length(CAST(execution_model AS BLOB)) BETWEEN 1 AND 256),
        CHECK (length(CAST(execution_effort AS BLOB)) BETWEEN 1 AND 64),
        CHECK ((supervisor_model IS NULL) = (supervisor_effort IS NULL)),
        CHECK (supervisor_model IS NULL OR
          length(CAST(supervisor_model AS BLOB)) BETWEEN 1 AND 256),
        CHECK (supervisor_effort IS NULL OR
          length(CAST(supervisor_effort AS BLOB)) BETWEEN 1 AND 64),
        CHECK (typeof(changed_files_json) = 'blob'),
        CHECK (length(changed_files_json) BETWEEN 2 AND 262144),
        CHECK (current_step IS NULL OR length(CAST(current_step AS BLOB)) <= 4096),
        CHECK (result_summary IS NULL OR length(CAST(result_summary AS BLOB)) <= 32768),
        CHECK (supervisor_summary IS NULL OR
          length(CAST(supervisor_summary AS BLOB)) <= 16384),
        CHECK (failure_code IS NULL OR
          length(CAST(failure_code AS BLOB)) BETWEEN 1 AND 128),
        CHECK (updated_at >= created_at)
    ) WITHOUT ROWID;
    CREATE TABLE grdb_migrations (identifier TEXT PRIMARY KEY NOT NULL);
    INSERT INTO "grdb_migrations" VALUES('BridgeServiceCore.v1');
    INSERT INTO "grdb_migrations" VALUES('BridgeServiceCore.v2');
    INSERT INTO "grdb_migrations" VALUES('BridgeServiceCore.v3');
    INSERT INTO "grdb_migrations" VALUES('BridgeServiceCore.v4');
    INSERT INTO "grdb_migrations" VALUES('BridgeServiceCore.v5');
    INSERT INTO "grdb_migrations" VALUES('BridgeServiceCore.v6');
    INSERT INTO "grdb_migrations" VALUES('BridgeServiceCore.v7');
    INSERT INTO "grdb_migrations" VALUES('BridgeServiceCore.v8');
    INSERT INTO "grdb_migrations" VALUES('BridgeServiceCore.v9');
    INSERT INTO "grdb_migrations" VALUES('BridgeServiceCore.v10');
    INSERT INTO "grdb_migrations" VALUES('BridgeServiceCore.v11');
    INSERT INTO "grdb_migrations" VALUES('BridgeServiceCore.v12');
    INSERT INTO "grdb_migrations" VALUES('BridgeServiceCore.v13');
    INSERT INTO "grdb_migrations" VALUES('BridgeServiceCore.v14');
    CREATE UNIQUE INDEX bridge_service_one_active_write_task
    ON bridge_service_tasks(project_id)
    WHERE permission_mode = 'workspace-write'
      AND status IN (
        'awaiting_local_approval', 'starting', 'running',
        'waiting_for_codex_approval', 'unknown'
      );
    CREATE INDEX bridge_service_tasks_updated
    ON bridge_service_tasks(updated_at DESC, task_id);
    CREATE INDEX bridge_service_tasks_project_updated
    ON bridge_service_tasks(project_id, updated_at DESC, task_id);
    CREATE INDEX bridge_service_task_events_task
    ON bridge_service_task_events(task_id, event_id DESC);
    CREATE INDEX bridge_service_agent_installations_provider
    ON bridge_service_agent_installations(provider_id, display_name COLLATE NOCASE);
    CREATE INDEX bridge_service_agent_installations_updated
    ON bridge_service_agent_installations(updated_at DESC, installation_id);
    CREATE INDEX bridge_service_agent_installation_artifacts_path
    ON bridge_service_agent_installation_artifacts(canonical_path);
    CREATE INDEX bridge_service_agent_installation_artifacts_updated
    ON bridge_service_agent_installation_artifacts(updated_at DESC, installation_id, role);
    CREATE INDEX bridge_service_task_messages_task
    ON bridge_service_task_messages(task_id, message_id);
    CREATE INDEX bridge_service_task_messages_activity
    ON bridge_service_task_messages(task_id, updated_at DESC, message_id DESC);
    DELETE FROM "sqlite_sequence";
    INSERT INTO "sqlite_sequence" VALUES('bridge_service_task_events',0);
    INSERT INTO "sqlite_sequence" VALUES('bridge_service_task_messages',0);
    COMMIT;
    """#
}
