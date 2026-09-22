import BridgeAgentCore
import BridgeDeepSeekHarnessACP
import BridgeServiceCore
import Foundation

extension BridgeServiceRequestController {
  func deepSeekReplacementRequest(
    installationID: AgentInstallationID,
    acceptReplacement: Bool
  ) async throws -> ServiceAgentRegistrationRequest? {
    guard acceptReplacement,
      let existing = try await composition.agentRegistry.installation(id: installationID),
      existing.providerID == .deepSeekHarness
    else { return nil }
    return try ServiceAgentAutoDiscovery.deepSeekReplacementRequest(
      existing: existing, dataPaths: composition.paths)
  }
}

extension ServiceAgentAutoDiscovery {
  static func managedDeepSeekExecutable(dataPaths: ServiceDataPaths) -> String {
    dataPaths.agentStateURL.appendingPathComponent(
      "DeepSeekHarnessRuntime/node_modules/@deepseek-ai/dsh/lib/bin.js"
    ).path
  }

  static func deepSeekReplacementRequest(
    existing: ServiceAgentInstallationRecord,
    dataPaths: ServiceDataPaths,
    environment: [String: String] = ToolDiscoveryEnvironment.current()
  ) throws -> ServiceAgentRegistrationRequest {
    guard
      let configuration = existing.artifacts.first(where: {
        $0.role == .launchConfiguration
      })?.canonicalPath
    else {
      throw AgentRuntimeError.invalidRequest("registration.configurationPath")
    }
    let managed = managedDeepSeekExecutable(dataPaths: dataPaths)
    let legacyPath = existing.executablePath.replacingOccurrences(of: "\\", with: "/")
    let isLegacyDemo = legacyPath.hasSuffix("/packages/examples/acp-demo/lib/bin.js")
    let executable =
      isLegacyDemo
      ? canonicalRegularFile(managed) ?? existing.executablePath : existing.executablePath
    let artifacts = try DeepSeekHarnessACPProfile.resolveArtifacts(
      executablePath: executable, configurationPath: configuration,
      sourceEnvironment: environment
    )
    return try ServiceAgentRegistrationRequest(
      providerID: existing.providerID,
      displayName: existing.displayName,
      executablePath: executable,
      trustProfile: existing.trustProfile,
      securityProfileID: existing.securityProfileID,
      enableOnSuccess: existing.isEnabled,
      configurationPath: configuration,
      artifacts: artifacts.filter { $0.key != .launchConfiguration }.map { role, path in
        try ServiceAgentInstallationArtifactRequest(role: role, path: path)
      }
    )
  }
}
