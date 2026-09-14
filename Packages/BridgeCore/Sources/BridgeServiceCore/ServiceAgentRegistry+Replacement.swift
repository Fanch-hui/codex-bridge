import BridgeAgentCore
import Foundation

extension ServiceAgentRegistry {
  /// Replaces an installation's executable and artifacts after a successful Probe.
  /// The existing installation identity remains stable for persisted tasks.
  public func replaceAndProbe(
    installationID: AgentInstallationID,
    request: ServiceAgentRegistrationRequest
  ) async throws -> ServiceAgentInstallationRecord {
    guard let existing = try await store.agentInstallation(id: installationID) else {
      throw ServiceStoreError.unknownAgentInstallation(installationID)
    }
    guard existing.providerID == request.providerID else {
      throw ServiceStoreError.invalidArgument("agentRegistration.providerID")
    }
    let provider = try provider(for: request.providerID)
    let identity = try captureIdentity(request.executablePath)
    let key = RegistrationKey(
      providerID: request.providerID,
      canonicalPath: identity.canonicalPath
    )
    guard activeRegistrations.insert(key).inserted else {
      throw ServiceAgentRegistryError.registrationInProgress(request.providerID)
    }
    defer { activeRegistrations.remove(key) }

    let siblings = try await store.agentInstallations(providerID: request.providerID)
    if siblings.contains(where: {
      $0.id != existing.id && $0.executableIdentity.canonicalPath == identity.canonicalPath
    }) {
      throw ServiceStoreError.duplicateAgentExecutable(
        providerID: request.providerID,
        canonicalPath: identity.canonicalPath
      )
    }

    let artifacts = try captureArtifacts(request.artifactRequests, at: now())
    let candidate = try await probeRecord(
      id: existing.id,
      provider: provider,
      displayName: request.displayName,
      executablePath: request.executablePath,
      identity: identity,
      trustProfile: request.trustProfile,
      securityProfileID: request.securityProfileID,
      isEnabled: existing.isEnabled,
      projectRoot: request.projectRoot,
      artifacts: artifacts,
      createdAt: existing.createdAt
    )
    guard candidate.availability == .available else {
      throw ServiceAgentRegistryError.replacementProbeFailed(
        existing.id, reason: candidate.lastProbeError ?? "The Agent replacement did not pass Probe."
      )
    }
    try await store.updateAgentInstallation(
      candidate,
      allowExecutableReplacement: true
    )
    return candidate
  }
}
