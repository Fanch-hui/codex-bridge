import BridgeAgentCore
import BridgeClaudeSDK
import BridgeServiceApplication
import Foundation

enum ServiceClaudeAssembly {
  static func make(
    stateDirectory: URL,
    runtimeBindings: ServiceAgentSetupRuntimeBindings,
    mcp: [ServiceAgentMCPScope: ServiceDeepSeekHarnessMCPConfiguration]
  ) throws -> ClaudeSDKProvider {
    try ClaudeSDKProvider(
      configuration: ClaudeSDKProviderConfiguration(
        runtimeBaseDirectory: stateDirectory.appendingPathComponent("ClaudeSDK", isDirectory: true)
          .path,
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
}
