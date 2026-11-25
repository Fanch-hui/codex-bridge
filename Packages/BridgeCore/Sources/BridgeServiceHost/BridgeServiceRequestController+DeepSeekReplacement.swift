import BridgeAgentCore
import BridgeAgentSetup
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
