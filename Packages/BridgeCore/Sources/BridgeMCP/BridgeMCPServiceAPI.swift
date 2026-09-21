import Foundation

public enum MCPServiceExposureMode: String, Codable, Equatable, Sendable {
  case readOnly = "read-only"
  case full
}
public protocol BridgeMCPServiceAPI: Sendable {
  func serviceCustomInstructions(
    deadline: ContinuousClock.Instant
  ) async throws -> String

  func serviceStatus(deadline: ContinuousClock.Instant) async throws -> BridgeStatusSnapshot

  func serviceProjects(
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectPage

  func serviceProject(
    projectID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectDetail

  func serviceAgents(
    projectID: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPAgentList

  func serviceProjectCommands(
    projectID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectCommands

  func serviceSearchProjectFiles(
    projectID: String,
    query: String,
    relativeDirectory: String?,
    caseSensitive: Bool,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectFileSearchPage

  func serviceReadProjectFile(
    projectID: String,
    relativePath: String,
    startLine: Int,
    lineCount: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectFileReadPage

  func serviceListProjectDirectory(
    projectID: String,
    relativeDirectory: String?,
    depth: Int,
    kind: String,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectDirectoryPage

  func serviceBatchReadProjectFiles(
    projectID: String,
    files: [MCPProjectFileBatchReadItemRequest],
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectFileBatchPage

  func serviceThreads(
    projectID: String,
    cursor: String?,
    limit: Int,
    search: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadPage

  func serviceReadThread(
    projectID: String,
    threadID: String,
    detail: MCPThreadDetail,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPThreadReadPage

  func serviceModels(deadline: ContinuousClock.Instant) async throws -> MCPModelList

  func serviceListSkills(
    projectID: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceSkillList

  func serviceReadSkill(
    skillName: String,
    projectID: String?,
    subpath: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceSkillDocument

  func serviceRunSkillAction(
    _ request: MCPRunSkillActionRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectCommandReceipt

  func serviceListTasks(
    projectID: String?, cursor: String?, limit: Int, deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskListPage

  func serviceTask(
    taskID: String,
    recentEventLimit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskSnapshot

  func serviceSubmitTask(
    _ submission: MCPServiceTaskSubmission,
    invocationContext: MCPInvocationContext,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskSubmissionReceipt

  func serviceSteerTask(
    taskID: String,
    expectedTurnID: String,
    input: String,
    mode: MCPTaskSteerMode,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskMutationReceipt

  func serviceInterruptTask(
    taskID: String,
    expectedTurnID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskMutationReceipt

  func serviceProjectChanges(
    projectID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectChanges

  func serviceDirectWriteFile(
    _ request: MCPDirectWriteRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectWriteReceipt

  func serviceDirectPreviewMutation(
    _ request: MCPDirectMutationRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectMutationPreview

  func serviceDirectApplyMutation(
    _ request: MCPDirectApplyMutationRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectMutationReceipt

  func serviceDirectUndoMutation(
    _ request: MCPDirectUndoMutationRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectMutationReceipt

  func serviceDirectEditFile(
    _ request: MCPDirectEditRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectEditReceipt

  func serviceDirectApplyPatch(
    _ request: MCPDirectPatchRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectPatchReceipt

  func serviceDirectManagePath(
    _ request: MCPDirectManagePathRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectManagePathReceipt

  func serviceDirectExecCommand(
    _ request: MCPDirectExecRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectCommandReceipt

  func serviceListDirectCommands(
    projectID: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectCommandPage

  func serviceDirectReadCommand(
    sessionID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectCommandOutput

  func serviceDirectReadCommand(
    sessionID: String,
    cursor: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectCommandOutput

  func serviceDirectWriteStdin(
    sessionID: String,
    data: String,
    deadline: ContinuousClock.Instant
  ) async throws

  func serviceDirectWriteStdin(
    sessionID: String,
    data: String,
    closeStdin: Bool,
    deadline: ContinuousClock.Instant
  ) async throws

  func serviceDirectInterruptCommand(
    sessionID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectCommandOutput

  func serviceDirectGitCommit(
    _ request: MCPDirectGitCommitRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectGitCommitReceipt
}

extension BridgeMCPServiceAPI {
  public func serviceDirectPreviewMutation(
    _ request: MCPDirectMutationRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectMutationPreview {
    throw BridgeMCPQueryError.unavailable
  }

  public func serviceDirectApplyMutation(
    _ request: MCPDirectApplyMutationRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectMutationReceipt {
    throw BridgeMCPQueryError.unavailable
  }

  public func serviceDirectUndoMutation(
    _ request: MCPDirectUndoMutationRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectMutationReceipt {
    throw BridgeMCPQueryError.unavailable
  }

  public func serviceListProjectDirectory(
    projectID: String,
    relativeDirectory: String?,
    depth: Int,
    kind: String,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectDirectoryPage {
    throw BridgeMCPQueryError.unavailable
  }

  public func serviceBatchReadProjectFiles(
    projectID: String,
    files: [MCPProjectFileBatchReadItemRequest],
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectFileBatchPage {
    throw BridgeMCPQueryError.unavailable
  }

  public func serviceDirectReadCommand(
    sessionID: String,
    cursor: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectCommandOutput {
    guard cursor == nil else { throw BridgeMCPQueryError.contractRejected }
    return try await serviceDirectReadCommand(sessionID: sessionID, deadline: deadline)
  }

  public func serviceListDirectCommands(
    projectID: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectCommandPage {
    throw BridgeMCPQueryError.unavailable
  }

  public func serviceListTasks(
    projectID: String?, cursor: String?, limit: Int, deadline: ContinuousClock.Instant
  ) async throws -> MCPTaskListPage {
    throw BridgeMCPQueryError.contractRejected
  }

  public func serviceAgents(
    projectID: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPAgentList {
    MCPAgentList(agents: [])
  }

  public func serviceCustomInstructions(
    deadline: ContinuousClock.Instant
  ) async throws -> String {
    ""
  }

  public func serviceDirectWriteStdin(
    sessionID: String,
    data: String,
    closeStdin: Bool,
    deadline: ContinuousClock.Instant
  ) async throws {
    guard !closeStdin else { throw BridgeMCPQueryError.contractRejected }
    try await serviceDirectWriteStdin(
      sessionID: sessionID,
      data: data,
      deadline: deadline
    )
  }
}
