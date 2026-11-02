import BridgeDomain
import Foundation

extension ServiceTaskManager {
  public func beginEmbeddedDSHExecution(
    sessionID: String,
    projectID: ProjectID,
    permissionMode: ServicePermissionMode = .full
  ) async throws -> String {
    let groupID = try await store.beginEmbeddedDSHExecution(
      sessionID: sessionID, projectID: projectID, permissionMode: permissionMode)
    changes.publish()
    return groupID
  }

  public func finishEmbeddedDSHExecution(sessionID: String, projectID: ProjectID) async throws {
    try await store.finishEmbeddedDSHExecution(sessionID: sessionID, projectID: projectID)
    changes.publish()
  }

  public func closeEmbeddedDSHExecutionAdmission(sessionID: String, projectID: ProjectID)
    async throws
  {
    try await store.closeEmbeddedDSHExecutionAdmission(sessionID: sessionID, projectID: projectID)
    changes.publish()
  }

  public func hasActiveExecutionGroup(projectID: ProjectID) async throws -> Bool {
    try await store.hasActiveExecutionGroup(projectID: projectID)
  }

  public func activeEmbeddedDSHSession(projectID: ProjectID) async throws -> String? {
    try await store.activeEmbeddedDSHSession(projectID: projectID)
  }

  public func activeEmbeddedDSHExecutionCount() async throws -> Int {
    try await store.activeEmbeddedDSHExecutionCount()
  }

  public func embeddedDSHExecutions() async throws -> [EmbeddedDSHExecution] {
    try await store.embeddedDSHExecutions()
  }

  public func embeddedDSHExecution(sessionID: String) async throws -> EmbeddedDSHExecution? {
    try await store.embeddedDSHExecution(sessionID: sessionID)
  }

  public func embeddedDSHSubagent(
    parentSessionID: String,
    childID: String
  ) async throws -> EmbeddedDSHSubagentBinding? {
    try await store.embeddedDSHSubagent(parentSessionID: parentSessionID, childID: childID)
  }

  public func isEmbeddedDSHTask(_ taskID: TaskID) async throws -> Bool {
    try await store.isEmbeddedDSHTask(taskID)
  }

  public func markEmbeddedDSHProcessUnknown(taskID: TaskID) async throws -> ServiceTaskRecord {
    let result = try await store.markEmbeddedDSHProcessUnknown(taskID: taskID, at: now())
    changes.publish()
    return result
  }

  /// The host verifies process exit and the original request outcome before calling this method.
  public func reconcileEmbeddedDSHSubagent(
    parentSessionID: String, childID: String, taskID: TaskID,
    outcome: EmbeddedDSHReconciledOutcome
  ) async throws -> ServiceTaskRecord {
    let result = try await store.reconcileEmbeddedDSHSubagent(
      parentSessionID: parentSessionID, childID: childID, taskID: taskID, outcome: outcome,
      at: now())
    changes.publish()
    return result
  }

  /// Use when process exit is confirmed and the original result cannot be recovered.
  public func confirmEmbeddedDSHSubagentProcessExited(
    parentSessionID: String, childID: String, taskID: TaskID
  ) async throws -> ServiceTaskRecord {
    try await reconcileEmbeddedDSHSubagent(
      parentSessionID: parentSessionID, childID: childID, taskID: taskID,
      outcome: .interrupted(
        summary: "The provider process stopped; its prior result was unavailable."))
  }

  public func embeddedDSHSubagents(parentSessionID: String) async throws
    -> [EmbeddedDSHSubagentBinding]
  {
    try await store.embeddedDSHSubagents(parentSessionID: parentSessionID)
  }

  public func pendingEmbeddedDSHResults(parentSessionID: String) async throws
    -> [EmbeddedDSHSubagentResult]
  {
    try await store.pendingEmbeddedDSHResults(parentSessionID: parentSessionID)
  }

  public func acknowledgeEmbeddedDSHResult(
    parentSessionID: String, childID: String, requestID: String, taskID: TaskID
  ) async throws {
    try await store.acknowledgeEmbeddedDSHResult(
      parentSessionID: parentSessionID, childID: childID, requestID: requestID, taskID: taskID)
    changes.publish()
  }
}
