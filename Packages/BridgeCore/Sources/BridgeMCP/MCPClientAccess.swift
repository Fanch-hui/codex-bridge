import MCP

/// Authorization for an external MCP client. Built-in clients retain their existing policy.
public enum MCPClientAccess: Sendable {
  case unrestricted
  case restricted(projectIDs: Set<String>, toolNames: Set<String>)

  public static let denied = MCPClientAccess.restricted(projectIDs: [], toolNames: [])

  func allowsTool(_ name: String) -> Bool {
    switch self {
    case .unrestricted: true
    case .restricted(_, let names): names.contains(name)
    }
  }

  func allowsProject(_ projectID: String) -> Bool {
    switch self {
    case .unrestricted: true
    case .restricted(let projects, _): projects.contains(projectID)
    }
  }

  func permits(_ name: MCPServiceToolName, arguments: [String: Value]?) -> Bool {
    guard allowsTool(name.rawValue) else { return false }
    guard case .restricted = self else { return true }
    switch name {
    case .bridgeStatus, .listProjects:
      return true
    case .getProject, .searchProjectFiles, .listProjectDirectory, .batchReadProjectFiles,
      .readProjectFile, .getProjectChanges, .directWriteProjectFile, .directEditProjectFile,
      .directApplyProjectPatch, .directManageProjectPath,
      .directExecCommand, .listDirectCommands, .directGitCommit:
      guard case .string(let projectID)? = arguments?["project_id"] else { return false }
      return allowsProject(projectID)
    default:
      return false
    }
  }

  public static let externalToolNames: Set<String> = Set(
    [
      MCPServiceToolName.bridgeStatus, .listProjects, .getProject, .searchProjectFiles,
      .listProjectDirectory, .batchReadProjectFiles, .readProjectFile, .getProjectChanges,
      .directWriteProjectFile, .directEditProjectFile, .directApplyProjectPatch,
      .directManageProjectPath, .directExecCommand, .listDirectCommands, .directReadCommand,
      .directWriteStdin, .directInterruptCommand, .directGitCommit,
    ].map(\.rawValue))
}
