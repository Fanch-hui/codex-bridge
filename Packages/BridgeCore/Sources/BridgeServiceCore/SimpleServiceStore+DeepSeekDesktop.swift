import BridgeAgentCore
import BridgeDomain
import Foundation
import GRDB

extension SimpleServiceStore {
  public func agentRuntimeBinding(taskID: TaskID) throws -> AgentRuntimeBinding? {
    try database.read { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: "SELECT * FROM bridge_service_dsh_task_bindings WHERE task_id = ?",
          arguments: [taskID.rawValue])
      else { return nil }
      guard let mode = DeepSeekHarnessConnectionMode(rawValue: row["connection_mode"]) else {
        throw ServiceStoreError.corruptRecord
      }
      return AgentRuntimeBinding(
        connectionMode: mode, profileID: row["profile_id"],
        requestID: row["request_id"])
    }
  }

  static func insertRuntimeBinding(
    _ binding: AgentRuntimeBinding?, taskID: TaskID,
    in db: Database
  ) throws {
    guard let binding else { return }
    guard
      try String.fetchOne(
        db,
        sql: "SELECT provider_id FROM bridge_service_tasks WHERE task_id = ?",
        arguments: [taskID.rawValue]) == AgentProviderID.deepSeekHarness.rawValue
    else {
      throw ServiceStoreError.invalidArgument("task.runtimeBinding")
    }
    guard !binding.requestID.isEmpty, binding.requestID.utf8.count <= 256,
      !binding.requestID.contains("\0"),
      binding.connectionMode != .nativeDesktop || binding.profileID?.isEmpty == false
    else { throw ServiceStoreError.invalidArgument("task.runtimeBinding") }
    try db.execute(
      sql: """
        INSERT INTO bridge_service_dsh_task_bindings(task_id, connection_mode, profile_id, request_id)
        VALUES (?, ?, ?, ?)
        """,
      arguments: [
        taskID.rawValue, binding.connectionMode.rawValue, binding.profileID,
        binding.requestID,
      ])
  }

  public func isDeepSeekDesktopSessionIndexed(
    scope: AgentNativeSessionDirectoryScope,
    sessionID: String, profileID: String
  ) throws -> Bool {
    try database.read { db in
      try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS(SELECT 1 FROM bridge_service_dsh_native_sessions
          WHERE installation_id = ? AND profile_id = ? AND project_id = ? AND session_id = ?)
          """, arguments: [scope.installationID.rawValue, profileID, scope.projectID, sessionID])
        ?? false
    }
  }

  public func indexDeepSeekDesktopSession(
    scope: AgentNativeSessionDirectoryScope,
    sessionID: String, profileID: String
  ) throws {
    guard scope.providerID == .deepSeekHarness, scope.region == profileID,
      !sessionID.isEmpty, sessionID.utf8.count <= 256
    else {
      throw ServiceStoreError.invalidArgument("history.binding")
    }
    try database.write { db in
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO bridge_service_dsh_native_sessions
          (installation_id, profile_id, project_id, session_id) VALUES (?, ?, ?, ?)
          """, arguments: [scope.installationID.rawValue, profileID, scope.projectID, sessionID])
    }
  }
}

extension ServiceTaskManager {
  public func agentRuntimeBinding(taskID: TaskID) async throws -> AgentRuntimeBinding? {
    try await store.agentRuntimeBinding(taskID: taskID)
  }
}
