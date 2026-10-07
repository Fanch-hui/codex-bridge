import BridgeAgentCore
import BridgeDirectCommand
import BridgeMCP
import BridgeServiceCore

extension BridgeServiceApplication {
  func resolveDirectCommandPolicy(
    _ request: MCPDirectExecRequest,
    project: ServiceProjectRecord,
    isValidatedSkillScript: Bool = false,
    requiresNetwork: Bool = false
  ) throws -> DirectCommandResolution {
    let unresolvedPolicyRequest = DirectCommandRequest(
      projectID: project.id,
      commandID: request.commandID,
      argv: request.argv,
      workingDirectory: request.workingDirectory,
      requiresNetwork: requiresNetwork,
      isValidatedSkillScript: isValidatedSkillScript
    )
    let resolvedExecutable: String?
    if let builtInExecutable = commandPolicy.preferredSystemBuiltInExecutable(
      project: project,
      request: unresolvedPolicyRequest
    ) {
      resolvedExecutable = builtInExecutable
    } else {
      resolvedExecutable = try Self.resolvedExecutableForPolicy(
        request: request,
        project: project
      )
    }
    return commandPolicy.resolve(
      project: project,
      request: DirectCommandRequest(
        projectID: project.id,
        commandID: request.commandID,
        argv: request.argv,
        resolvedExecutable: resolvedExecutable,
        workingDirectory: request.workingDirectory,
        requiresNetwork: requiresNetwork,
        isValidatedSkillScript: isValidatedSkillScript
      )
    )
  }

  static func resolvedExecutableForPolicy(
    request: MCPDirectExecRequest,
    project: ServiceProjectRecord
  ) throws -> String? {
    let requestedExecutable =
      request.argv.first
      ?? request.commandID.flatMap { commandID in
        project.workspaceCommands.first(where: { $0.id == commandID })?.executable
      }
    guard let requestedExecutable, !requestedExecutable.isEmpty else { return nil }
    guard
      let resolved = try resolvedLaunchArgv(
        [requestedExecutable],
        project: project,
        allowUnresolvedBareExecutable: true
      ).first,
      AgentPathSemantics.isAbsolute(resolved, style: .current)
    else { return nil }
    return resolved
  }
}
