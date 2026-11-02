import BridgeAgentCore
import BridgeDomain
import Foundation
import GRDB

extension SimpleServiceStore {
  static func existingEmbeddedDSHSubmission(
    task: ServiceTaskRecord,
    identity: EmbeddedDSHSubagentIdentity,
    attachments: [AgentImageAttachment],
    in db: Database
  ) throws -> ServiceTaskCreationResult? {
    try validateEmbeddedDSHIdentity(identity)
    guard task.source == .mcpClient, task.sourceClientID == identity.sourceClientID,
      let requestID = task.clientRequestID, !task.isQueued
    else {
      throw ServiceStoreError.invalidArgument("dsh.subagentSubmission")
    }
    let input = try Row.fetchOne(
      db,
      sql: """
        SELECT task_id FROM bridge_service_embedded_dsh_inputs
        WHERE parent_session_id = ? AND child_id = ? AND request_id = ?
        """,
      arguments: [identity.parentSessionID, identity.childID, requestID]
    )
    guard let input else { return nil }
    guard let previousTaskID: String = input["task_id"],
      let row = try taskRow(id: TaskID(rawValue: previousTaskID), in: db)
    else {
      throw ServiceStoreError.invalidArgument("dsh.subagentTaskRemoved")
    }
    let previous = try decodeTask(row)
    guard try taskAttachments(taskID: previousTaskID, in: db) == attachments else {
      throw ServiceStoreError.invalidArgument("task.attachments")
    }
    return try reusedResult(existing: previous, requested: task)
  }

  static func claimExecutionGroup(
    task: ServiceTaskRecord,
    embeddedDSHSubagent identity: EmbeddedDSHSubagentIdentity?,
    in db: Database
  ) throws -> String? {
    if let identity {
      try validateEmbeddedDSHIdentity(identity)
      guard task.source == .mcpClient, task.sourceClientID == identity.sourceClientID,
        task.clientRequestID != nil, !task.isQueued,
        let group = try executionGroup(projectID: task.projectID, in: db),
        group["root_session_id"] as String? == identity.parentSessionID,
        group["root_active"] as Int == 1,
        group["root_closing"] as Int == 0
      else {
        throw ServiceStoreError.invalidArgument("dsh.executionOwner")
      }
      guard
        task.permissionMode == .readOnly
          || group["root_permission_mode"] as String == ServicePermissionMode.full.rawValue
      else { throw ServiceStoreError.invalidArgument("dsh.subagentPermission") }
      if let binding = try embeddedDSHBinding(
        parentSessionID: identity.parentSessionID, childID: identity.childID, in: db
      ) {
        guard binding.projectID == task.projectID, binding.providerID == task.providerID,
          binding.installationID == task.installationID,
          binding.executionModel == task.executionModel,
          binding.executionEffort == task.executionEffort
        else { throw ServiceStoreError.invalidArgument("dsh.subagentBinding") }
        guard let status = binding.currentStatus, status.isTerminal else {
          throw ServiceStoreError.invalidArgument("dsh.subagentBusy")
        }
        guard let nativeSessionID = binding.nativeSessionID,
          task.requestedThreadID == nativeSessionID
        else { throw ServiceStoreError.invalidArgument("dsh.subagentSession") }
      } else if task.requestedThreadID != nil {
        throw ServiceStoreError.invalidArgument("dsh.subagentSession")
      }
      return group["group_id"]
    }
    guard task.permissionMode == .full, task.state.status.holdsWriteSlot, !task.isQueued else {
      return nil
    }
    guard try executionGroup(projectID: task.projectID, in: db) == nil else {
      throw ServiceStoreError.activeWriteTaskExists(task.projectID)
    }
    let groupID = "task:" + task.id.rawValue
    try db.execute(
      sql: """
        INSERT INTO bridge_service_execution_groups
          (project_id, group_id, root_session_id, root_active, root_closing, root_permission_mode)
        VALUES (?, ?, NULL, 0, 0, NULL)
        """,
      arguments: [task.projectID.rawValue, groupID]
    )
    return groupID
  }

  static func linkEmbeddedDSHSubagent(
    task: ServiceTaskRecord,
    identity: EmbeddedDSHSubagentIdentity,
    in db: Database
  ) throws {
    guard let requestID = task.clientRequestID else {
      throw ServiceStoreError.invalidArgument("dsh.subagentSubmission")
    }
    try db.execute(
      sql: """
        INSERT INTO bridge_service_embedded_dsh_subagents
          (parent_session_id, child_id, project_id, provider_id, installation_id,
           current_task_id, current_request_id, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(parent_session_id, child_id) DO UPDATE SET
          current_task_id = excluded.current_task_id,
          current_request_id = excluded.current_request_id,
          updated_at = excluded.updated_at
        """,
      arguments: [
        identity.parentSessionID, identity.childID, task.projectID.rawValue,
        task.providerID, task.installationID, task.id.rawValue, requestID,
        task.createdAt.timeIntervalSince1970, task.updatedAt.timeIntervalSince1970,
      ]
    )
    try db.execute(
      sql: """
        INSERT INTO bridge_service_embedded_dsh_inputs
          (parent_session_id, child_id, request_id, task_id) VALUES (?, ?, ?, ?)
        """,
      arguments: [identity.parentSessionID, identity.childID, requestID, task.id.rawValue]
    )
  }

  static func isEmbeddedDSHTask(_ taskID: TaskID, in db: Database) throws -> Bool {
    try Int.fetchOne(
      db,
      sql: "SELECT 1 FROM bridge_service_embedded_dsh_inputs WHERE task_id = ? LIMIT 1",
      arguments: [taskID.rawValue]
    ) != nil
  }
}
