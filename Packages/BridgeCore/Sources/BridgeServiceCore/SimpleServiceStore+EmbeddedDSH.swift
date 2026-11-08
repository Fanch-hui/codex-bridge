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
        if let row = try Self.executionGroup(projectID: projectID, in: db) {
          guard row["root_session_id"] as String? == sessionID else {
            throw ServiceStoreError.activeWriteTaskExists(projectID)
          }
          guard row["root_closing"] as Int == 0 else {
            throw ServiceStoreError.invalidArgument("dsh.executionClosing")
          }
          if permissionMode == .readOnly {
            let activeWriteChild = try Int.fetchOne(
              db,
              sql: """
                SELECT 1 FROM bridge_service_tasks
                WHERE execution_group_id = ? AND permission_mode = 'workspace-write'
                  AND queue_state = 'active' AND status IN (
                    'awaiting_local_approval', 'starting', 'running',
                    'waiting_for_codex_approval', 'unknown') LIMIT 1
                """,
              arguments: [row["group_id"] as String]
            )
            guard activeWriteChild == nil else {
              throw ServiceStoreError.invalidArgument("dsh.permissionModeBusy")
            }
          }
          try db.execute(
            sql: """
              UPDATE bridge_service_execution_groups SET root_active = 1, root_permission_mode = ?
              WHERE project_id = ?
              """,
            arguments: [permissionMode.rawValue, projectID.rawValue]
          )
          return row["group_id"]
        }
        let groupID = "dsh:" + UUID().uuidString.lowercased()
        try db.execute(
          sql: """
            INSERT INTO bridge_service_execution_groups
              (project_id, group_id, root_session_id, root_active, root_closing, root_permission_mode)
            VALUES (?, ?, ?, 1, 0, ?)
            """,
          arguments: [projectID.rawValue, groupID, sessionID, permissionMode.rawValue]
        )
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
        guard group["root_session_id"] as String? == sessionID else {
          throw ServiceStoreError.invalidArgument("dsh.executionOwner")
        }
        try db.execute(
          sql: "UPDATE bridge_service_execution_groups SET root_closing = 1 WHERE project_id = ?",
          arguments: [projectID.rawValue]
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
        guard group["root_session_id"] as String? == sessionID else {
          throw ServiceStoreError.invalidArgument("dsh.executionOwner")
        }
        let groupID: String = group["group_id"]
        try db.execute(
          sql: "UPDATE bridge_service_execution_groups SET root_active = 0 WHERE project_id = ?",
          arguments: [projectID.rawValue]
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
        return row["root_session_id"] as String?
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
            "SELECT COUNT(*) FROM bridge_service_execution_groups WHERE root_session_id IS NOT NULL"
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
            SELECT project_id, group_id, root_session_id, root_active, root_closing, root_permission_mode
            FROM bridge_service_execution_groups WHERE root_session_id IS NOT NULL
            ORDER BY project_id
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
          sql: "SELECT * FROM bridge_service_execution_groups WHERE root_session_id = ?",
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

  static func releaseInactiveExecutionGroup(_ groupID: String, in db: Database) throws {
    try db.execute(
      sql: """
        DELETE FROM bridge_service_execution_groups
        WHERE group_id = ? AND root_active = 0 AND NOT EXISTS (
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
