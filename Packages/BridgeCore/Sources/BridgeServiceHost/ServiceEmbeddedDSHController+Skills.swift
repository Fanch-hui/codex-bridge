import BridgeACP
import BridgeAgentCore
import BridgeDomain
import BridgeServiceApplication
import BridgeServiceCore
import BridgeSkills
import Foundation

extension ServiceEmbeddedDSHController {
  public func notifySkillsInvalidated() async {
    _ = try? await runtime?.callIfRunning(action: "skills.invalidate", payload: .object([:]))
  }

  func importLegacyActionSkills(_ payload: [String: ACPJSONValue]) async throws -> ACPJSONValue {
    guard let skillHub = application.skillHub else {
      throw SkillHubError.operationFailed("技能中心服务暂不可用。")
    }
    let data = try ACPJSONValue.object(payload).encodedData()
    let projects = self.projects
    let resultData = try await skillHub.handleAction(
      "importDirectory",
      payloadData: data,
      resolveProject: { projectID in
        guard let project = try await projects.project(id: ProjectID(rawValue: projectID)) else {
          throw ServiceStoreError.unknownProject(ProjectID(rawValue: projectID))
        }
        try project.root.validateCurrentIdentity()
        return URL(fileURLWithPath: project.root.canonicalPath, isDirectory: true)
      }
    )
    return try JSONDecoder().decode(ACPJSONValue.self, from: resultData)
  }

  func handleSkillCallback(_ input: ACPJSONValue) async throws -> ACPJSONValue {
    guard let payload = input.objectValue else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.skills")
    }
    guard let skillHub = application.skillHub else {
      throw SkillHubError.operationFailed("技能中心服务暂不可用。")
    }
    let operation = try Self.requiredString(payload, "operation")
    let (projectRoot, projectID) = await resolveSkillProject(forCwd: payload["cwd"]?.stringValue)

    switch operation {
    case "list":
      let candidates = try await skillHub.workbenchCandidates(
        projectRoot: projectRoot, projectID: projectID)
      return .object(["candidates": try Self.value(["items": candidates])["items"] ?? .array([])])

    case "get":
      let name = try Self.requiredString(payload, "name")
      let locatorSlug = payload["locator"]?.objectValue?["slug"]?.stringValue ?? name
      let occurrenceID = payload["locator"]?.objectValue?["occurrenceID"]?.stringValue
      let definition = try await skillHub.workbenchDefinition(
        slug: locatorSlug,
        occurrenceID: occurrenceID,
        projectRoot: projectRoot,
        projectID: projectID
      )
      if let definition {
        return .object(["skill": try Self.value(definition)])
      }
      return .object(["skill": .null])

    default:
      throw ServiceStoreError.invalidArgument("embedded_dsh.skills_operation")
    }
  }

  func refreshSkillsIfDiskChanged(for sessionID: String) async {
    guard let skillHub = application.skillHub else { return }
    let record = try? await project(for: sessionID)
    let rootURL = record.map { URL(fileURLWithPath: $0.root.canonicalPath, isDirectory: true) }
    await skillHub.refreshIfDiskChanged(for: rootURL, projectID: record?.id.rawValue)
  }

  private func resolveSkillProject(forCwd cwd: String?) async -> (URL?, String?) {
    guard let cwd, !cwd.isEmpty else { return (nil, nil) }
    let normalized = URL(fileURLWithPath: cwd, isDirectory: true).standardizedFileURL.path
    let chatOnlyPath = dataRoot.appendingPathComponent("WorkbenchChat", isDirectory: true)
      .standardizedFileURL.path
    if Self.samePath(normalized, chatOnlyPath) { return (nil, nil) }
    guard let allProjects = try? await projects.projects() else { return (nil, nil) }

    var bestMatch: ServiceProjectRecord?
    for project in allProjects {
      let rootPath = project.root.canonicalPath
      if Self.samePath(normalized, rootPath)
        || AgentPathSemantics.isContained(normalized, in: rootPath)
      {
        if let current = bestMatch {
          if rootPath.count > current.root.canonicalPath.count {
            bestMatch = project
          }
        } else {
          bestMatch = project
        }
      }
    }
    guard let matched = bestMatch else { return (nil, nil) }
    return (
      URL(fileURLWithPath: matched.root.canonicalPath, isDirectory: true), matched.id.rawValue
    )
  }
}
