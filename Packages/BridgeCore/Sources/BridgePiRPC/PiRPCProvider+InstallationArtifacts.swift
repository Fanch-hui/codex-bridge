import BridgeAgentCore

extension PiRPCProvider: AgentInstallationArtifactProviding {
  public func installationArtifacts(for installation: AgentInstallation) async throws
    -> [AgentInstallationArtifact]
  {
    try PiRuntimeProfile.make(
      installation: installation, request: nil, configuration: configuration
    ).artifacts
  }
}
