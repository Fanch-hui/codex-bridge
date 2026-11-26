import BridgeAgentCore
import BridgeClaudeSDK
import BridgeServiceApplication
import BridgeServiceCore
import Foundation

package enum ServiceClaudeAssembly {
  package static func make(
    stateDirectory: URL,
    projects: ServiceProjectService, settings: ServiceSettings,
    runtimeBindings: ServiceAgentSetupRuntimeBindings,
    mcp: [ServiceAgentMCPScope: ServiceDeepSeekHarnessMCPConfiguration]
  ) throws -> ClaudeSDKProvider {
    try ClaudeSDKProvider(
      configuration: ClaudeSDKProviderConfiguration(
        runtimeBaseDirectory: stateDirectory.appendingPathComponent("ClaudeSDK", isDirectory: true)
          .path,
        probeDirectory: {
          try await ServiceClaudeAssembly.probeDirectory(projects: projects, settings: settings)
        },
        runtimeConfiguration: { installation in
          let staged = await runtimeBindings.staged(for: installation.executablePath)
          let node =
            staged?.nodeExecutablePath
            ?? installation.artifacts.first(where: { $0.role == .nodeInterpreter })?.canonicalPath
          return ClaudeSDKRuntimeConfiguration(nodeExecutablePath: node)
        },
        resources: { request, _ in
          try await ServiceAgentMCPResources.claude(request: request, configurations: mcp)
        },
        configuredMCPServerCount: { _ in
          try await mcp[.claudeCode]?.enabledServerCount() ?? 0
        }
      ))
  }

  package static func probeDirectory(
    projects: ServiceProjectService, settings: ServiceSettings
  ) async throws -> String? {
    let selectedID = try await settings.string(for: .claudeCodeProbeProjectID)
    let projectID: String?
    if let selectedID {
      projectID = selectedID
    } else {
      projectID = try await settings.string(for: .defaultWorkspaceProjectID)
    }
    guard let projectID else { return nil }
    guard let project = try await projects.projects().first(where: { $0.id.rawValue == projectID })
    else { throw AgentRuntimeError.invalidRequest("claude.probe_project_unavailable") }
    do {
      try project.root.validateCurrentIdentity()
    } catch {
      throw AgentRuntimeError.invalidRequest("claude.probe_project_unavailable")
    }
    return project.root.canonicalPath
  }
}
