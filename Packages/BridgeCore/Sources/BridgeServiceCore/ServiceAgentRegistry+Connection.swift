import BridgeAgentCore
import Foundation

extension ServiceAgentRegistry {
  /// Connects a discovered installation without creating duplicate records.
  /// Existing available records are changed only after a replacement Probe succeeds.
  public func connect(
    _ request: ServiceAgentRegistrationRequest
  ) async throws -> ServiceAgentInstallationRecord {
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

    let existing = try await installations(providerID: request.providerID)
      .first { $0.executableIdentity.canonicalPath == identity.canonicalPath }
    if let existing {
      return try await connectExisting(
        existing,
        provider: provider,
        request: request,
        identity: identity
      )
    }

    let createdAt = now()
    let artifacts = try captureArtifacts(request.artifactRequests, at: createdAt)
    let record = try await probeRecord(
      id: makeInstallationID(),
      provider: provider,
      displayName: request.displayName,
      executablePath: request.executablePath,
      identity: identity,
      trustProfile: request.trustProfile,
      securityProfileID: request.securityProfileID,
      isEnabled: false,
      projectRoot: request.projectRoot,
      artifacts: artifacts,
      createdAt: createdAt
    )
    let connected = try record.replacingEnabled(
      record.availability == .available,
      updatedAt: record.updatedAt
    )
    try await store.insertAgentInstallation(connected)
    return connected
  }

  private func connectExisting(
    _ existing: ServiceAgentInstallationRecord,
    provider: any AgentProvider,
    request: ServiceAgentRegistrationRequest,
    identity: ServiceAgentExecutableIdentity
  ) async throws -> ServiceAgentInstallationRecord {
    let artifacts: [ServiceAgentInstallationArtifact]
    do {
      artifacts = try captureArtifacts(request.artifactRequests, at: now())
    } catch {
      if existing.availability == .available {
        throw ServiceAgentRegistryError.connectionProbeFailed(existing.id)
      }
      throw error
    }
    let candidate = try await probeRecord(
      id: existing.id,
      provider: provider,
      displayName: request.displayName,
      executablePath: existing.executablePath,
      identity: identity,
      trustProfile: request.trustProfile,
      securityProfileID: request.securityProfileID,
      isEnabled: existing.isEnabled,
      projectRoot: request.projectRoot,
      artifacts: artifacts,
      createdAt: existing.createdAt
    )
    guard candidate.availability == .available else {
      if existing.availability == .available {
        throw ServiceAgentRegistryError.connectionProbeFailed(existing.id)
      }
      let unavailable = try candidate.replacingEnabled(false, updatedAt: now())
      try await store.updateAgentInstallation(unavailable)
      return unavailable
    }
    let enabled = try candidate.replacingEnabled(true, updatedAt: now())
    try await store.updateAgentInstallation(enabled)
    return enabled
  }
}
