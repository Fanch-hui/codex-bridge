import BridgeACP
import BridgeAgentCore
import Foundation

public struct ClaudeSessionResources: Sendable {
  public let selectedSkills: [AgentSelectedSkill]
  public let mcpServers: [String: ACPJSONValue]

  public init(selectedSkills: [AgentSelectedSkill] = [], mcpServers: [String: ACPJSONValue] = [:]) {
    self.selectedSkills = selectedSkills
    self.mcpServers = mcpServers
  }
}

public struct ClaudeSDKRuntimeConfiguration: Equatable, Sendable {
  public let nodeExecutablePath: String?
  public let hostDirectory: String?

  public init(nodeExecutablePath: String? = nil, hostDirectory: String? = nil) {
    self.nodeExecutablePath = nodeExecutablePath
    self.hostDirectory = hostDirectory
  }
}

public struct ClaudeSDKProviderConfiguration: Sendable {
  public let runtimeBaseDirectory: String
  public let sourceEnvironment: [String: String]
  public let hostDirectory: String?
  public let runtimeConfiguration:
    @Sendable (AgentInstallation) async throws -> ClaudeSDKRuntimeConfiguration
  public let resources:
    @Sendable (AgentExecutionRequest, AgentInstallation) async throws -> ClaudeSessionResources
  public let configuredMCPServerCount: @Sendable (AgentInstallation) async throws -> Int
  public let transportFactory:
    @Sendable (ACPProcessTransportConfiguration) throws -> any ACPTransport

  public init(
    runtimeBaseDirectory: String,
    sourceEnvironment: [String: String] = ToolDiscoveryEnvironment.current(),
    hostDirectory: String? = nil,
    runtimeConfiguration:
      @escaping @Sendable (AgentInstallation) async throws -> ClaudeSDKRuntimeConfiguration = {
        installation in
        ClaudeSDKRuntimeConfiguration(
          nodeExecutablePath: installation.artifacts.first(where: { $0.role == .nodeInterpreter })?
            .canonicalPath)
      },
    resources:
      @escaping @Sendable (AgentExecutionRequest, AgentInstallation) async throws ->
      ClaudeSessionResources = { _, _ in .init() },
    configuredMCPServerCount: @escaping @Sendable (AgentInstallation) async throws -> Int = { _ in 0
    },
    transportFactory:
      @escaping @Sendable (ACPProcessTransportConfiguration) throws -> any ACPTransport = {
        try ACPProcessTransport.launch(configuration: $0)
      }
  ) {
    self.runtimeBaseDirectory = runtimeBaseDirectory
    self.sourceEnvironment = sourceEnvironment
    self.hostDirectory = hostDirectory
    self.runtimeConfiguration = runtimeConfiguration
    self.resources = resources
    self.configuredMCPServerCount = configuredMCPServerCount
    self.transportFactory = transportFactory
  }
}
