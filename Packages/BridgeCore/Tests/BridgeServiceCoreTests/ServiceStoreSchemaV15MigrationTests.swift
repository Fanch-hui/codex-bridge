import Foundation
import GRDB
import XCTest

@testable import BridgeServiceCore

#if canImport(Darwin)
  import Darwin
#endif

final class ServiceStoreSchemaV15MigrationTests: XCTestCase {
  func testInvalidPreMigrationBackupIsRebuiltAndSupersededCopiesArePruned()
    async throws
  {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "bridge-schema-backup-recovery-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "service.sqlite").path
    try await makeVersionFourteenDatabase(at: path)

    let staleBackup = path + ".pre-v8"
    XCTAssertTrue(FileManager.default.createFile(atPath: staleBackup, contents: Data("stale".utf8)))
    let currentBackup = path + ".pre-v15"
    XCTAssertTrue(FileManager.default.createFile(atPath: currentBackup, contents: Data()))

    let store = try SimpleServiceStore(path: path)
    XCTAssertFalse(FileManager.default.fileExists(atPath: staleBackup))
    let backupAttributes = try FileManager.default.attributesOfItem(atPath: currentBackup)
    XCTAssertGreaterThan((backupAttributes[.size] as? NSNumber)?.int64Value ?? 0, 0)
    let backup = try DatabaseQueue(path: currentBackup)
    let backupVersion = try await backup.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT schema_version FROM bridge_service_meta WHERE singleton = 1"
      )
    }
    XCTAssertEqual(backupVersion, 14)
    let currentVersion = try await store.database.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT schema_version FROM bridge_service_meta WHERE singleton = 1"
      )
    }
    XCTAssertEqual(currentVersion, 17)
  }

  func testVersionFourteenDatabaseMigratesPathsAndPreservesRows() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "bridge-schema-migration-v15-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appending(path: "service.sqlite").path

    try await makeVersionFourteenDatabase(at: path)
    try assertVersionFourteenBaseline(at: path)
    let store = try SimpleServiceStore(path: path)

    let migrated = try await store.database.read { db in
      let version = try Int.fetchOne(
        db,
        sql: "SELECT schema_version FROM bridge_service_meta WHERE singleton = 1"
      )
      let rows = try [
        "bridge_service_projects",
        "bridge_service_tasks",
        "bridge_service_task_events",
        "bridge_service_task_messages",
        "bridge_service_agent_installations",
        "bridge_service_agent_installation_artifacts",
      ].map { table in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")
      }
      let projectSQL = try String.fetchOne(
        db,
        sql: "SELECT sql FROM sqlite_master WHERE name = 'bridge_service_projects'"
      )
      let installationSQL = try String.fetchOne(
        db,
        sql: "SELECT sql FROM sqlite_master WHERE name = 'bridge_service_agent_installations'"
      )
      let artifactSQL = try String.fetchOne(
        db,
        sql:
          "SELECT sql FROM sqlite_master WHERE name = 'bridge_service_agent_installation_artifacts'"
      )
      let message = try String.fetchOne(
        db,
        sql: "SELECT content FROM bridge_service_task_messages WHERE task_id = 'tsk-v14'"
      )
      let artifactPath = try String.fetchOne(
        db,
        sql: "SELECT canonical_path FROM bridge_service_agent_installation_artifacts"
      )
      return (version, rows, projectSQL, installationSQL, artifactSQL, message, artifactPath)
    }

    XCTAssertEqual(migrated.0, 17)
    XCTAssertEqual(migrated.1, [1, 1, 1, 1, 1, 1])
    XCTAssertTrue(migrated.2?.contains("GLOB '[A-Za-z]'") ?? false)
    XCTAssertTrue(migrated.3?.contains("GLOB '[A-Za-z]'") ?? false)
    XCTAssertTrue(migrated.4?.contains("GLOB '[A-Za-z]'") ?? false)
    XCTAssertEqual(migrated.5, "Preserved message")
    XCTAssertEqual(migrated.6, "/tmp/v14-config")

    let indexes = try await store.database.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT name FROM sqlite_master
          WHERE type = 'index' AND sql IS NOT NULL
          ORDER BY name
          """
      )
    }
    XCTAssertEqual(
      Set(indexes),
      Set([
        "bridge_service_agent_installations_provider",
        "bridge_service_agent_installations_updated",
        "bridge_service_agent_installation_artifacts_path",
        "bridge_service_agent_installation_artifacts_updated",
        "bridge_service_one_active_write_task",
        "bridge_service_task_events_task",
        "bridge_service_task_messages_agent_activity",
        "bridge_service_task_messages_activity",
        "bridge_service_task_messages_task",
        "bridge_service_tasks_project_updated",
        "bridge_service_tasks_updated",
        "bridge_service_task_queue_project_order",
      ])
    )
    let foreignKeyCounts = try await store.database.read { db in
      try [
        "bridge_service_projects",
        "bridge_service_tasks",
        "bridge_service_task_events",
        "bridge_service_task_messages",
        "bridge_service_agent_installations",
        "bridge_service_agent_installation_artifacts",
      ].map { table in
        try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))").count
      }
    }
    XCTAssertEqual(foreignKeyCounts, [0, 1, 1, 1, 0, 1])

    try await store.database.write { db in
      try db.execute(
        sql: """
          INSERT INTO bridge_service_projects (
            project_id, name, canonical_path, root_device, root_inode,
            read_permission, write_permission, network_permission,
            direct_command_mode, workspace_commands_json, direct_blacklist_json,
            created_at, updated_at
          ) VALUES ('prj-windows', 'Windows', ?, '3', '4',
            'allowed', 'allowed', 'denied', 'safe', CAST('[]' AS BLOB),
            CAST('[]' AS BLOB), 3, 4)
          """,
        arguments: [#"C:\Work\Project"#]
      )
      try db.execute(
        sql: """
          INSERT INTO bridge_service_projects (
            project_id, name, canonical_path, root_device, root_inode,
            read_permission, write_permission, network_permission,
            direct_command_mode, workspace_commands_json, direct_blacklist_json,
            created_at, updated_at
          ) VALUES ('prj-unc', 'UNC', ?, '7', '8',
            'allowed', 'allowed', 'denied', 'safe', CAST('[]' AS BLOB),
            CAST('[]' AS BLOB), 5, 6)
          """,
        arguments: [#"\\Server\Share\Project"#]
      )
      try db.execute(
        sql: """
          INSERT INTO bridge_service_agent_installations (
            installation_id, provider_id, display_name, executable_path,
            canonical_executable_path, executable_device, executable_inode,
            executable_size, executable_mtime_ns, executable_sha256, version,
            protocol_revision, adapter_revision, trust_profile, security_profile_id,
            is_enabled, availability, capabilities_json, last_probe_error,
            last_probed_at, created_at, updated_at
          ) VALUES ('ainst-windows', 'open_code', 'Windows', ?, ?, '3', '4',
            '5', 6, ?, '1', '1', 1, 'managed', NULL, 1, 'unavailable',
            CAST('{}' AS BLOB), NULL, NULL, 3, 4)
          """,
        arguments: [
          #"C:\Tools\opencode.exe"#, #"C:\Tools\opencode.exe"#,
          String(repeating: "0", count: 64),
        ]
      )
    }

    let nativePaths = try await store.database.read { db in
      try String.fetchAll(
        db,
        sql: "SELECT canonical_path FROM bridge_service_projects ORDER BY project_id"
      )
    }
    XCTAssertEqual(
      Set(nativePaths),
      Set(["/tmp/v14", #"C:\Work\Project"#, #"\\Server\Share\Project"#])
    )

    var rejectedRelativePath = false
    do {
      try await store.database.write { db in
        try db.execute(
          sql: """
            INSERT INTO bridge_service_projects (
              project_id, name, canonical_path, root_device, root_inode,
              read_permission, write_permission, network_permission,
              direct_command_mode, workspace_commands_json, direct_blacklist_json,
              created_at, updated_at
            ) VALUES ('prj-relative', 'Relative', 'relative/project', '9', '10',
              'allowed', 'allowed', 'denied', 'safe', CAST('[]' AS BLOB),
              CAST('[]' AS BLOB), 7, 8)
            """
        )
      }
    } catch {
      rejectedRelativePath = true
    }
    XCTAssertTrue(rejectedRelativePath)

    #if !os(Windows)
      var metadata = stat()
      XCTAssertEqual(lstat(path + ".pre-v15", &metadata), 0)
      XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
    #endif
  }

  private func makeVersionFourteenDatabase(at path: String) async throws {
    let legacy = try DatabaseQueue(path: path)
    try await legacy.writeWithoutTransaction { db in
      try db.execute(sql: ServiceStoreV14Fixture.schema)
      try Self.insertLegacyRows(in: db)
    }
  }

  private func assertVersionFourteenBaseline(at path: String) throws {
    let database = try DatabaseQueue(path: path)
    try database.read { db in
      let expectedColumns: [String: Set<String>] = [
        "bridge_service_projects": [
          "project_id", "name", "canonical_path", "root_device", "root_inode",
          "root_volume_uuid", "read_permission", "write_permission", "network_permission",
          "direct_command_mode", "workspace_commands_json", "direct_blacklist_json",
          "created_at", "updated_at",
        ],
        "bridge_service_tasks": [
          "task_id", "project_id", "source", "source_client_id", "client_request_id",
          "prompt", "requested_thread_id", "codex_thread_id", "codex_turn_id", "status",
          "supervisor_status", "execution_model", "execution_effort", "supervisor_model",
          "supervisor_effort", "permission_mode", "network_allowed", "access_mode", "fast_mode",
          "current_step", "changed_files_json", "result_summary", "supervisor_summary",
          "failure_code", "created_at", "updated_at", "provider_id", "installation_id",
          "selection_mode", "provider_session_id", "provider_run_id",
        ],
        "bridge_service_task_events": ["event_id", "task_id", "kind", "summary", "created_at"],
        "bridge_service_task_messages": [
          "message_id", "task_id", "message_key", "role", "content", "created_at", "kind",
          "tool_name", "tool_status", "tool_arguments", "updated_at",
        ],
        "bridge_service_agent_installations": [
          "installation_id", "provider_id", "display_name", "executable_path",
          "canonical_executable_path", "executable_device", "executable_inode", "executable_size",
          "executable_mtime_ns", "executable_sha256", "version", "protocol_revision",
          "adapter_revision", "trust_profile", "security_profile_id", "is_enabled", "availability",
          "capabilities_json", "last_probe_error", "last_probed_at", "created_at", "updated_at",
        ],
        "bridge_service_agent_installation_artifacts": [
          "installation_id", "role", "canonical_path", "artifact_device", "artifact_inode",
          "artifact_size", "artifact_mtime_ns", "artifact_sha256", "created_at", "updated_at",
        ],
      ]
      for (table, columns) in expectedColumns {
        let actual = Set(
          try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { row in
            row["name"] as String
          }
        )
        XCTAssertEqual(actual, columns, "v14 baseline drifted for \(table)")
      }
      let indexes = Set(
        try String.fetchAll(
          db,
          sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND sql IS NOT NULL"
        )
      )
      XCTAssertEqual(
        indexes,
        Set([
          "bridge_service_agent_installations_provider",
          "bridge_service_agent_installations_updated",
          "bridge_service_agent_installation_artifacts_path",
          "bridge_service_agent_installation_artifacts_updated",
          "bridge_service_one_active_write_task",
          "bridge_service_task_events_task",
          "bridge_service_task_messages_activity",
          "bridge_service_task_messages_task",
          "bridge_service_tasks_project_updated",
          "bridge_service_tasks_updated",
        ])
      )
      let projectSQL = try String.fetchOne(
        db,
        sql: "SELECT sql FROM sqlite_master WHERE name = 'bridge_service_projects'"
      )
      XCTAssertTrue(projectSQL?.contains("CHECK (substr(canonical_path, 1, 1) = '/')") == true)
      let messageSQL = try String.fetchOne(
        db,
        sql: "SELECT sql FROM sqlite_master WHERE name = 'bridge_service_task_messages'"
      )
      XCTAssertTrue(messageSQL?.contains("'declined', 'cancelled'") == true)
    }
  }

  private static func insertLegacyRows(in db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO bridge_service_projects (
          project_id, name, canonical_path, root_device, root_inode,
          read_permission, write_permission, network_permission,
          direct_command_mode, workspace_commands_json, direct_blacklist_json,
          created_at, updated_at
        ) VALUES ('prj-v14', 'Legacy', '/tmp/v14', '1', '2',
          'allowed', 'allowed', 'denied', 'safe', CAST('[]' AS BLOB),
          CAST('[]' AS BLOB), 1, 2)
        """)
    try db.execute(
      sql: """
        INSERT INTO bridge_service_tasks (
          task_id, project_id, source, source_client_id, prompt, status,
          supervisor_status, execution_model, execution_effort, permission_mode,
          network_allowed, access_mode, fast_mode, changed_files_json,
          created_at, updated_at, provider_id, selection_mode
        ) VALUES ('tsk-v14', 'prj-v14', 'mcp.client', 'qwen.studio', 'Legacy',
          'completed', 'disabled', 'legacy-model', 'medium', 'read-only', 0,
          'request-approval', 0, CAST('[]' AS BLOB), 1, 2, 'codex', 'legacy_codex')
        """)
    try db.execute(
      sql: """
        INSERT INTO bridge_service_task_events (task_id, kind, summary, created_at)
        VALUES ('tsk-v14', 'task.created', 'Preserved event', 3)
        """)
    try db.execute(
      sql: """
        INSERT INTO bridge_service_task_messages (
          task_id, message_key, role, content, created_at, kind, updated_at
        ) VALUES ('tsk-v14', 'agent:1', 'agent', 'Preserved message', 4, 'agent', 4)
        """)
    try db.execute(
      sql: """
        INSERT INTO bridge_service_agent_installations (
          installation_id, provider_id, display_name, executable_path,
          canonical_executable_path, executable_device, executable_inode,
          executable_size, executable_mtime_ns, executable_sha256, version,
          protocol_revision, adapter_revision, trust_profile, security_profile_id,
          is_enabled, availability, capabilities_json, last_probe_error,
          last_probed_at, created_at, updated_at
        ) VALUES ('ainst-v14', 'open_code', 'Legacy', '/tmp/opencode', '/tmp/opencode',
          '1', '2', '3', 4, ?, '1', '1', 1, 'managed', NULL, 1, 'unavailable',
          CAST('{}' AS BLOB), NULL, NULL, 1, 2)
        """,
      arguments: [String(repeating: "0", count: 64)]
    )
    try db.execute(
      sql: """
        INSERT INTO bridge_service_agent_installation_artifacts (
          installation_id, role, canonical_path, artifact_device, artifact_inode,
          artifact_size, artifact_mtime_ns, artifact_sha256, created_at, updated_at
        ) VALUES ('ainst-v14', 'launch_configuration', '/tmp/v14-config', '1', '2',
          '3', 4, ?, 1, 2)
        """,
      arguments: [String(repeating: "0", count: 64)]
    )
  }
}
