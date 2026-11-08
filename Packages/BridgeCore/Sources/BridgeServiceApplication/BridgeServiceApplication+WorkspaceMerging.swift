import BridgeAgentCore
import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  /// The caller must hold the root session's workspace write lease for the entire merge.
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
        if try await tasks.activeEmbeddedDSHSession(projectID: projectID) == sessionID {
          return nil
        }
        return try await tasks.activeWriteTask(projectID: projectID)
      },
      activeEmbeddedDSHSession: {
        let active = try await tasks.activeEmbeddedDSHSession(projectID: projectID)
        return active == sessionID ? nil : active
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
