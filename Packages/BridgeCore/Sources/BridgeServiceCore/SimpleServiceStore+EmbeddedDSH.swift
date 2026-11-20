import BridgeDomain
import Foundation
import GRDB

extension SimpleServiceStore {
  public func hasActiveExecutionGroup(projectID: ProjectID) throws -> Bool {
    do {
      return try database.read { db in
        try Self.executionGroup(projectID: projectID, in: db) != nil
      }
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func beginEmbeddedDSHExecution(
    sessionID: String,
    projectID: ProjectID,
    permissionMode: ServicePermissionMode = .full
  ) throws -> String {
    try ServiceValidation.identifier(sessionID, field: "dsh.sessionID", maximumBytes: 1_024)
    do {
      return try database.write { db in
        guard try Self.projectRow(id: projectID, in: db) != nil else {
          throw ServiceStoreError.unknownProject(projectID)
        }
        let existingGroup = try Self.executionGroup(projectID: projectID, in: db)
        let groupID: String = existingGroup?["group_id"] ?? "dsh:" + UUID().uuidString.lowercased()
        if existingGroup != nil, try !Self.hasExecutionRoots(groupID, in: db) {
          throw ServiceStoreError.activeWriteTaskExists(projectID)
        }
        if let root = try Self.executionRoot(sessionID: sessionID, in: db) {
          guard root["group_id"] as String == groupID else {
            throw ServiceStoreError.invalidArgument("dsh.executionOwner")
          }
          guard root["root_closing"] as Int == 0 else {
            throw ServiceStoreError.invalidArgument("dsh.executionClosing")
          }
        }
        if permissionMode == .readOnly {
          let writer = try Int.fetchOne(
            db,
            sql: """
              SELECT 1 FROM bridge_service_tasks t
              JOIN bridge_service_embedded_dsh_inputs i ON i.task_id = t.task_id
              WHERE i.parent_session_id = ? AND t.permission_mode = 'workspace-write'
                AND t.queue_state = 'active' AND t.status IN
                  ('awaiting_local_approval', 'starting', 'running', 'waiting_for_codex_approval', 'unknown')
              LIMIT 1
              """, arguments: [sessionID])
          guard writer == nil else {
            throw ServiceStoreError.invalidArgument("dsh.permissionModeBusy")
          }
        }
        if existingGroup == nil {
          try db.execute(
            sql: """
              INSERT INTO bridge_service_execution_groups
                (project_id, group_id, root_active, root_closing) VALUES (?, ?, 0, 0)
              """, arguments: [projectID.rawValue, groupID])
        }
        try db.execute(
          sql: """
            INSERT INTO bridge_service_execution_roots
              (group_id, root_session_id, root_active, root_closing, root_permission_mode)
            VALUES (?, ?, 1, 0, ?)
            ON CONFLICT(root_session_id) DO UPDATE SET root_active = 1,
              root_permission_mode = excluded.root_permission_mode
            """, arguments: [groupID, sessionID, permissionMode.rawValue])
        return groupID
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func closeEmbeddedDSHExecutionAdmission(sessionID: String, projectID: ProjectID) throws {
    try ServiceValidation.identifier(sessionID, field: "dsh.sessionID", maximumBytes: 1_024)
    do {
      try database.write { db in
        guard let group = try Self.executionGroup(projectID: projectID, in: db) else { return }
        guard let root = try Self.executionRoot(sessionID: sessionID, in: db) else { return }
        guard root["group_id"] as String == group["group_id"] as String else {
          throw ServiceStoreError.invalidArgument("dsh.executionOwner")
        }
        try db.execute(
          sql:
            "UPDATE bridge_service_execution_roots SET root_closing = 1 WHERE root_session_id = ?",
          arguments: [sessionID]
        )
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func finishEmbeddedDSHExecution(sessionID: String, projectID: ProjectID) throws {
    try ServiceValidation.identifier(sessionID, field: "dsh.sessionID", maximumBytes: 1_024)
    do {
      try database.write { db in
        guard let group = try Self.executionGroup(projectID: projectID, in: db) else { return }
        guard let root = try Self.executionRoot(sessionID: sessionID, in: db) else { return }
        guard root["group_id"] as String == group["group_id"] as String else {
          throw ServiceStoreError.invalidArgument("dsh.executionOwner")
        }
        let groupID: String = group["group_id"]
        try db.execute(
          sql:
            "UPDATE bridge_service_execution_roots SET root_active = 0 WHERE root_session_id = ?",
          arguments: [sessionID]
        )
        try Self.releaseInactiveExecutionGroup(groupID, in: db)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func activeEmbeddedDSHSession(projectID: ProjectID) throws -> String? {
    do {
      return try database.read { db in
        guard let row = try Self.executionGroup(projectID: projectID, in: db) else { return nil }
        return try String.fetchOne(
          db,
          sql:
            "SELECT root_session_id FROM bridge_service_execution_roots WHERE group_id = ? ORDER BY root_session_id LIMIT 1",
          arguments: [row["group_id"] as String])
      }
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func activeEmbeddedDSHExecutionCount() throws -> Int {
    do {
      return try database.read { db in
        try Int.fetchOne(
          db,
          sql:
            "SELECT COUNT(*) FROM bridge_service_execution_roots"
        ) ?? 0
      }
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func embeddedDSHExecutions() throws -> [EmbeddedDSHExecution] {
    do {
      return try database.read { db in
        let rows = try Row.fetchAll(
          db,
          sql: """
            SELECT g.project_id, r.* FROM bridge_service_execution_roots r
            JOIN bridge_service_execution_groups g USING (group_id)
            ORDER BY g.project_id, r.root_session_id
            """
        )
        return try rows.map(Self.decodeEmbeddedDSHExecution)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func embeddedDSHExecution(sessionID: String) throws -> EmbeddedDSHExecution? {
    try ServiceValidation.identifier(sessionID, field: "dsh.sessionID", maximumBytes: 1_024)
    do {
      return try database.read { db in
        try Row.fetchOne(
          db,
          sql:
            "SELECT g.project_id, r.* FROM bridge_service_execution_roots r JOIN bridge_service_execution_groups g USING (group_id) WHERE r.root_session_id = ?",
          arguments: [sessionID]
        ).map(Self.decodeEmbeddedDSHExecution)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  static func decodeEmbeddedDSHExecution(_ row: Row) throws -> EmbeddedDSHExecution {
    guard let permissionMode = ServicePermissionMode(rawValue: row["root_permission_mode"]) else {
      throw ServiceStoreError.corruptRecord
    }
    return EmbeddedDSHExecution(
      sessionID: row["root_session_id"], projectID: ProjectID(rawValue: row["project_id"]),
      groupID: row["group_id"], rootActive: (row["root_active"] as Int) == 1,
      closing: (row["root_closing"] as Int) == 1, permissionMode: permissionMode
    )
  }

  public func embeddedDSHSubagent(
    parentSessionID: String,
    childID: String
  ) throws -> EmbeddedDSHSubagentBinding? {
    try Self.validateEmbeddedDSHIdentity(.init(parentSessionID: parentSessionID, childID: childID))
    do {
      return try database.read { db in
        try Self.embeddedDSHBinding(parentSessionID: parentSessionID, childID: childID, in: db)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func isEmbeddedDSHTask(_ taskID: TaskID) throws -> Bool {
    do {
      return try database.read { db in try Self.isEmbeddedDSHTask(taskID, in: db) }
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  public func embeddedDSHSubagents(parentSessionID: String) throws -> [EmbeddedDSHSubagentBinding] {
    try ServiceValidation.identifier(parentSessionID, field: "dsh.sessionID", maximumBytes: 1_024)
    do {
      return try database.read { db in
        let rows = try Row.fetchAll(
          db,
          sql: Self.embeddedDSHBindingSQL
            + " WHERE b.parent_session_id = ? ORDER BY b.created_at, b.child_id",
          arguments: [parentSessionID]
        )
        return try rows.map(Self.decodeEmbeddedDSHBinding)
      }
    } catch let error as ServiceStoreError {
      throw error
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  static func executionGroup(projectID: ProjectID, in db: Database) throws -> Row? {
    try Row.fetchOne(
      db,
      sql: "SELECT * FROM bridge_service_execution_groups WHERE project_id = ?",
      arguments: [projectID.rawValue]
    )
  }

  static func executionRoot(sessionID: String, in db: Database) throws -> Row? {
    try Row.fetchOne(
      db, sql: "SELECT * FROM bridge_service_execution_roots WHERE root_session_id = ?",
      arguments: [sessionID])
  }

  static func hasExecutionRoots(_ groupID: String, in db: Database) throws -> Bool {
    try Int.fetchOne(
      db, sql: "SELECT 1 FROM bridge_service_execution_roots WHERE group_id = ? LIMIT 1",
      arguments: [groupID]) != nil
  }

  static func releaseInactiveExecutionGroup(_ groupID: String, in db: Database) throws {
    try db.execute(
      sql: """
        DELETE FROM bridge_service_execution_roots
        WHERE group_id = ? AND root_active = 0 AND NOT EXISTS (
          SELECT 1 FROM bridge_service_tasks t
          JOIN bridge_service_embedded_dsh_inputs i ON i.task_id = t.task_id
          WHERE i.parent_session_id = bridge_service_execution_roots.root_session_id
            AND t.queue_state = 'active' AND t.status IN
              ('awaiting_local_approval', 'starting', 'running', 'waiting_for_codex_approval', 'unknown')
        )
        """, arguments: [groupID])
    try db.execute(
      sql: """
        DELETE FROM bridge_service_execution_groups
        WHERE group_id = ? AND NOT EXISTS (
          SELECT 1 FROM bridge_service_execution_roots r WHERE r.group_id = bridge_service_execution_groups.group_id
        ) AND NOT EXISTS (
          SELECT 1 FROM bridge_service_tasks
          WHERE execution_group_id = ? AND queue_state = 'active'
            AND status IN ('awaiting_local_approval', 'starting', 'running',
                           'waiting_for_codex_approval', 'unknown')
        )
        """,
      arguments: [groupID, groupID]
    )
  }

  static func validateEmbeddedDSHIdentity(_ identity: EmbeddedDSHSubagentIdentity) throws {
    try ServiceValidation.identifier(
      identity.parentSessionID, field: "dsh.parentSessionID", maximumBytes: 1_024)
    try ServiceValidation.identifier(identity.childID, field: "dsh.childID", maximumBytes: 1_024)
  }

  static let embeddedDSHBindingSQL = """
    SELECT b.*, t.provider_session_id, t.codex_thread_id, t.requested_thread_id,
           t.execution_model, t.execution_effort, t.status
    FROM bridge_service_embedded_dsh_subagents b
    LEFT JOIN bridge_service_tasks t ON t.task_id = b.current_task_id
    """

  static func embeddedDSHBinding(
    parentSessionID: String,
    childID: String,
    in db: Database
  ) throws -> EmbeddedDSHSubagentBinding? {
    try Row.fetchOne(
      db,
      sql: embeddedDSHBindingSQL + " WHERE b.parent_session_id = ? AND b.child_id = ?",
      arguments: [parentSessionID, childID]
    ).map(decodeEmbeddedDSHBinding)
  }

  static func decodeEmbeddedDSHBinding(_ row: Row) throws -> EmbeddedDSHSubagentBinding {
    let status: String? = row["status"]
    if let status, ServiceTaskStatus(rawValue: status) == nil {
      throw ServiceStoreError.corruptRecord
    }
    let taskID: String? = row["current_task_id"]
    return EmbeddedDSHSubagentBinding(
      parentSessionID: row["parent_session_id"],
      childID: row["child_id"],
      projectID: ProjectID(rawValue: row["project_id"]),
      providerID: row["provider_id"],
      installationID: row["installation_id"],
      currentTaskID: taskID.map { TaskID(rawValue: $0) },
      currentRequestID: row["current_request_id"],
      nativeSessionID: (row["provider_session_id"] as String?)
        ?? (row["codex_thread_id"] as String?)
          ?? (row["requested_thread_id"] as String?),
      executionModel: row["execution_model"],
      executionEffort: row["execution_effort"],
      currentStatus: status.flatMap(ServiceTaskStatus.init(rawValue:)),
      createdAt: Date(timeIntervalSince1970: row["created_at"]),
      updatedAt: Date(timeIntervalSince1970: row["updated_at"])
    )
  }
}
