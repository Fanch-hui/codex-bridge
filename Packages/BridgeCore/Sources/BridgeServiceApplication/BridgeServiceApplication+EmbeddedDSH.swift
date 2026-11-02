import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public func beginEmbeddedDSHExecution(
    sessionID: String,
    projectID: ProjectID,
    permissionMode: ServicePermissionMode = .full
  ) async throws -> String {
    let project = try await readableProject(projectID.rawValue)
    do { try project.root.validateCurrentIdentity() } catch {
      throw BridgeMCPQueryError.pathChanged
    }
    let taskToken = try await workspaceGate.beginTaskAdmission()
    let workspaceToken: String
    do {
      workspaceToken = try await workspaceGate.beginCodexAdmission(projectID: projectID)
    } catch {
      await workspaceGate.endTaskAdmission(token: taskToken)
      throw Self.publicWorkspaceBusyError(error)
    }
    do {
      let group = try await tasks.beginEmbeddedDSHExecution(
        sessionID: sessionID, projectID: projectID, permissionMode: permissionMode)
      await workspaceGate.endCodexAdmission(projectID: projectID, token: workspaceToken)
      await workspaceGate.endTaskAdmission(token: taskToken)
      return group
    } catch {
      await workspaceGate.endCodexAdmission(projectID: projectID, token: workspaceToken)
      await workspaceGate.endTaskAdmission(token: taskToken)
      if let storeError = error as? ServiceStoreError { throw Self.publicStoreError(storeError) }
      throw error
    }
  }

  public func closeEmbeddedDSHExecutionAdmission(sessionID: String, projectID: ProjectID)
    async throws
  {
    try await tasks.closeEmbeddedDSHExecutionAdmission(sessionID: sessionID, projectID: projectID)
  }

  /// The host calls this after the DSH root has stopped producing workspace effects.
  public func finishEmbeddedDSHExecution(sessionID: String, projectID: ProjectID) async throws {
    try await tasks.finishEmbeddedDSHExecution(sessionID: sessionID, projectID: projectID)
  }

  public func embeddedDSHSubagent(
    parentSessionID: String,
    childID: String
  ) async throws -> EmbeddedDSHSubagentBinding? {
    try await tasks.embeddedDSHSubagent(parentSessionID: parentSessionID, childID: childID)
  }

  public func embeddedDSHExecutions() async throws -> [EmbeddedDSHExecution] {
    try await tasks.embeddedDSHExecutions()
  }

  public func embeddedDSHExecution(sessionID: String) async throws -> EmbeddedDSHExecution? {
    try await tasks.embeddedDSHExecution(sessionID: sessionID)
  }

  public func embeddedDSHSubagents(parentSessionID: String) async throws
    -> [EmbeddedDSHSubagentBinding]
  {
    try await tasks.embeddedDSHSubagents(parentSessionID: parentSessionID)
  }

  public func pendingEmbeddedDSHResults(parentSessionID: String) async throws
    -> [EmbeddedDSHSubagentResult]
  {
    try await tasks.pendingEmbeddedDSHResults(parentSessionID: parentSessionID)
  }

  public func acknowledgeEmbeddedDSHResult(
    parentSessionID: String, childID: String, requestID: String, taskID: TaskID
  ) async throws {
    try await tasks.acknowledgeEmbeddedDSHResult(
      parentSessionID: parentSessionID, childID: childID, requestID: requestID, taskID: taskID)
  }

  /// The host verifies process exit and the original request outcome before calling this method.
  public func reconcileEmbeddedDSHSubagent(
    parentSessionID: String, childID: String, taskID: TaskID,
    outcome: EmbeddedDSHReconciledOutcome
  ) async throws -> ServiceTaskRecord {
    try await tasks.reconcileEmbeddedDSHSubagent(
      parentSessionID: parentSessionID, childID: childID, taskID: taskID, outcome: outcome)
  }

  /// Use when process exit is confirmed and the original result cannot be recovered.
  public func confirmEmbeddedDSHSubagentProcessExited(
    parentSessionID: String, childID: String, taskID: TaskID
  ) async throws -> ServiceTaskRecord {
    try await tasks.confirmEmbeddedDSHSubagentProcessExited(
      parentSessionID: parentSessionID, childID: childID, taskID: taskID)
  }

  /// Stop the DSH root first, then call this method to stop and drain its children.
  public func stopEmbeddedDSHExecution(
    sessionID: String, projectID: ProjectID,
    releasesRoot: Bool = true
  ) async throws {
    try await tasks.closeEmbeddedDSHExecutionAdmission(sessionID: sessionID, projectID: projectID)
    let children = try await tasks.embeddedDSHSubagents(parentSessionID: sessionID)
    var pendingRecovery: TaskID?
    for child in children where child.projectID == projectID {
      guard let taskID = child.currentTaskID, let status = child.currentStatus, !status.isTerminal
      else {
        continue
      }
      if status == .unknown {
        pendingRecovery = pendingRecovery ?? taskID
        continue
      }
      await coordinator.stop(taskID: taskID, summary: "The DSH parent stopped this subagent.")
      guard let stopped = try await tasks.task(id: taskID), stopped.state.status.isTerminal else {
        throw BridgeMCPQueryError.busy
      }
    }
    if releasesRoot {
      try await tasks.finishEmbeddedDSHExecution(sessionID: sessionID, projectID: projectID)
    }
    if let pendingRecovery {
      throw EmbeddedDSHRecoveryError.pendingProcessReconciliation(taskID: pendingRecovery)
    }
  }
}
