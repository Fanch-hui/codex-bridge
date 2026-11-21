import BridgeMCP
import BridgeSkills
import Foundation

extension BridgeServiceApplication {
  public func serviceRunSkillAction(
    _ request: MCPRunSkillActionRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectCommandReceipt {
    try Self.checkDeadline(deadline)
    let project = try await readableProject(request.projectID)
    guard request.arguments.count <= 128,
      request.arguments.allSatisfy({ $0.utf8.count <= 4_096 })
    else { throw BridgeMCPQueryError.contractRejected }
    let manifest: SkillManifest
    do {
      let root = URL(fileURLWithPath: project.root.canonicalPath)
      if let skillHub {
        guard
          let resolved = try await skillHub.findActiveSkill(
            named: request.skillName, projectRoot: root, projectID: request.projectID)
        else {
          throw BridgeMCPQueryError.skillNotFound
        }
        manifest = resolved.manifest
      } else {
        let manifests = try await skillScanner.scanSkills(for: root)
        guard let matched = manifests.first(where: { $0.name == request.skillName }) else {
          throw BridgeMCPQueryError.skillNotFound
        }
        manifest = matched
      }
    } catch let error as BridgeMCPQueryError {
      throw error
    } catch {
      throw Self.publicSkillError(error)
    }
    let launch: SkillScanner.SkillActionLaunch
    do {
      launch = try await skillScanner.resolveAction(request.actionName, in: manifest)
    } catch {
      throw Self.publicSkillError(error)
    }
    let argv = launch.argvPrefix + request.arguments
    let requiresNetwork = launch.action.networkRequirement != .denied
    // Only an explicit denial enters the network sandbox. Unspecified actions
    // are conservatively treated as network-capable by project policy and local
    // approval; guessing `denied` would break legitimate loopback/network tools.
    let denyNetwork = launch.action.networkRequirement == .denied
    let directRequest = MCPDirectExecRequest(
      projectID: request.projectID,
      argv: argv,
      workingDirectory: nil,
      tty: false,
      yieldTimeMS: request.yieldTimeMS,
      timeoutMS: request.timeoutMS,
      clientRequestID: request.clientRequestID
    )
    return try await serviceDirectExecCommand(
      directRequest,
      deadline: deadline,
      isValidatedSkillScript: true,
      requiresNetwork: requiresNetwork,
      denyNetwork: denyNetwork
    )
  }
}
