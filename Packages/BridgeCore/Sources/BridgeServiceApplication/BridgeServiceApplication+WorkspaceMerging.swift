import BridgeAgentCore
import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  /// The caller holds the shared project write lease, excluding every root and its children.
  public func acquireEmbeddedDSHWorkspaceMergeLease(
    sessionID: String, projectID: ProjectID, operationID: String,
    permittingRecoveryID: String? = nil
  ) async throws -> DirectWorkspaceLease {
    let project = try await readableProject(projectID.rawValue)
    do { try project.root.validateCurrentIdentity() } catch {
      throw BridgeMCPQueryError.pathChanged
    }
    let tasks = self.tasks
    return try await workspaceGate.acquireDirectLease(
      projectID: projectID,
      owner: .directFileOperation(operationID: operationID),
      activeCodexWriteTask: {
        if try await tasks.activeEmbeddedDSHSession(projectID: projectID) != nil {
          return nil
        }
        return try await tasks.activeWriteTask(projectID: projectID)
      },
      activeEmbeddedDSHSession: {
        guard let owner = try await tasks.activeEmbeddedDSHSession(projectID: projectID),
          owner != sessionID
        else { return nil }
        // Multiple roots can share a project's execution group and serialize their merges.
        if !sessionID.isEmpty,
          try await tasks.embeddedDSHExecution(sessionID: sessionID)?.projectID == projectID
        {
          return nil
        }
        return owner
      },
      permittingRecoveryID: permittingRecoveryID
    )
  }

  public func workspaceMergeChangeStreams() -> [AsyncStream<Void>] {
    [tasks.changes.subscribe(), workspaceGate.changes.subscribe()]
  }

  public func pendingWorkspaceMergeRecovery(projectID: ProjectID) async throws
    -> ServiceWorkspaceMergeRecovery?
  {
    try await tasks.workspaceMergeRecovery(projectID: projectID)
  }

  public func workspaceMergeRecoveryChanged() {
    workspaceGate.workspaceRecoveryChanged()
  }

  public func prepareWorkspaceValidationCommand(
    projectID: ProjectID, executable: String, arguments: [String]
  ) async throws -> [String] {
    let project = try await applyingDirectConfiguration(to: readableProject(projectID.rawValue))
    let request = MCPDirectExecRequest(
      projectID: projectID.rawValue, argv: [executable] + arguments)
    let resolution = try resolveDirectCommandPolicy(request, project: project)
    guard resolution.allowed, resolution.workingDirectory == nil else {
      throw BridgeMCPQueryError.commandDenied("workspace_validation_policy")
    }
    let argv = try Self.resolvedLaunchArgv(resolution.argv, project: project)
    guard let path = argv.first,
      AgentPathSemantics.isAbsolute(path, style: .current),
      !AgentPathSemantics.isContained(path, in: project.root.canonicalPath, style: .current)
    else { throw BridgeMCPQueryError.commandDenied("workspace_validation_executable") }
    let program = URL(fileURLWithPath: path).lastPathComponent.lowercased()
    guard
      ![
        "sh", "bash", "zsh", "fish", "dash", "cmd", "cmd.exe", "powershell",
        "powershell.exe", "pwsh", "pwsh.exe",
      ].contains(program)
    else { throw BridgeMCPQueryError.commandDenied("workspace_validation_shell") }
    return argv
  }
}
