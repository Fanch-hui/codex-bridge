import BridgeDirectCommand
import BridgeDomain
import BridgeProjects
import BridgeServiceCore
import Foundation
import XCTest

enum DirectCommandPolicyTestSupport {
  static func project(
    mode: ServiceDirectCommandMode = .safe,
    write: ProjectPermission = .allowed,
    network: ProjectPermission = .denied,
    root: URL = FileManager.default.temporaryDirectory,
    commands: [ServiceWorkspaceCommand] = []
  ) throws -> ServiceProjectRecord {
    try ServiceProjectRecord(
      id: ProjectID(rawValue: "prj-safe-built-in"),
      name: "Safe built-in policy",
      root: ServiceRootIdentity(capturing: root),
      accessPolicy: ProjectAccessPolicy(
        read: .allowed,
        write: write,
        network: network
      ),
      directCommandMode: mode,
      workspaceCommands: commands,
      createdAt: Date(),
      updatedAt: Date()
    )
  }

  static func resolve(
    _ argv: [String],
    policy: DirectCommandPolicy = DirectCommandPolicy(),
    project: ServiceProjectRecord
  ) -> DirectCommandResolution {
    policy.resolve(
      project: project,
      request: DirectCommandRequest(
        projectID: project.id,
        commandID: nil,
        argv: argv
      )
    )
  }

  static func resolveBuiltIn(
    _ argv: [String],
    policy: DirectCommandPolicy = DirectCommandPolicy(),
    project: ServiceProjectRecord
  ) throws -> DirectCommandResolution {
    let request = DirectCommandRequest(
      projectID: project.id,
      commandID: nil,
      argv: argv
    )
    #if os(Windows)
      guard
        let rule = policy.effectiveSafeCommandRules.first(where: { $0.executable == argv.first }),
        let executable = policy.preferredSystemBuiltInExecutable(
          project: project,
          request: DirectCommandRequest(
            projectID: project.id, commandID: nil,
            argv: [rule.executable] + rule.argumentsPrefix)
        )
      else {
        throw XCTSkip("the requested built-in has no trusted Windows executable")
      }
      return policy.resolve(
        project: project,
        request: DirectCommandRequest(
          projectID: project.id,
          commandID: nil,
          argv: argv,
          resolvedExecutable: executable
        )
      )
    #else
      return policy.resolve(project: project, request: request)
    #endif
  }
}
