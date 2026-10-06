import BridgeAgentCore
import Foundation

extension ServiceAgentRegistry {
  public func validateDesktopInstallation(installationID: AgentInstallationID) async throws
    -> ServiceAgentInstallationRecord
  {
    guard let record = try await store.agentInstallation(id: installationID),
      record.providerID == .deepSeekHarness
    else {
      throw ServiceAgentRegistryError.installationUnavailable(installationID)
    }
    let identity = try captureIdentity(record.executablePath)
    guard identity.hasSameContent(as: record.executableIdentity),
      artifactsHaveSameContent(try captureArtifacts(record.artifacts, at: now()), record.artifacts),
      archivesHaveSameContent(
        try captureArchiveArtifacts(record.runtimeArtifacts), record.runtimeArtifacts)
    else { throw ServiceAgentRegistryError.installationNeedsReview(installationID) }
    return record
  }

  public func validateForRuntimeBinding(
    installationID: AgentInstallationID,
    projectRoot: String? = nil, runtimeBinding: AgentRuntimeBinding?
  ) async throws
    -> ServiceAgentInstallationRecord
  {
    guard let runtimeBinding else {
      return try await validateForExecution(installationID: installationID)
    }
    let record = try await validateDesktopInstallation(installationID: installationID)
    guard record.isEnabled else {
      throw ServiceAgentRegistryError.installationUnavailable(installationID)
    }
    let provider = try provider(for: record.providerID)
    let result = await provider.probe(
      try AgentProbeRequest(
        installation: record.agentInstallation(),
        projectRoot: projectRoot, runtimeBinding: runtimeBinding))
    guard result.available, result.installation.id == record.id,
      result.installation.providerID == record.providerID
    else {
      throw ServiceAgentRegistryError.connectionProbeFailed(installationID)
    }
    return try ServiceAgentInstallationRecord(
      id: record.id, providerID: record.providerID,
      displayName: record.displayName, executablePath: record.executablePath,
      executableIdentity: record.executableIdentity,
      version: result.installation.version ?? record.version,
      protocolRevision: result.installation.protocolRevision,
      adapterRevision: provider.descriptor.adapterRevision,
      trustProfile: record.trustProfile, securityProfileID: record.securityProfileID,
      isEnabled: record.isEnabled, availability: .available, capabilities: result.capabilities,
      artifacts: record.artifacts, runtimeArtifacts: record.runtimeArtifacts,
      lastProbeError: nil, lastProbedAt: record.lastProbedAt, createdAt: record.createdAt,
      updatedAt: record.updatedAt)
  }

  func selectedRuntimeBinding(for record: ServiceAgentInstallationRecord) async throws
    -> AgentRuntimeBinding?
  {
    guard record.providerID == .deepSeekHarness else { return nil }
    let settings = ServiceSettings(store: store)
    return AgentRuntimeBinding(
      connectionMode: try await settings.deepSeekHarnessConnectionMode(),
      profileID: try await settings.deepSeekHarnessDesktopTrust(installationID: record.id)?
        .profileID,
      requestID: "catalog")
  }
}
