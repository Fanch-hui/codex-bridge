import BridgeAgentCore
import Foundation

extension ServiceAgentRegistry {
  public func validateForExecution(
    installationID: AgentInstallationID
  ) async throws -> ServiceAgentInstallationRecord {
    guard let existing = try await store.agentInstallation(id: installationID) else {
      throw ServiceStoreError.unknownAgentInstallation(installationID)
    }
    let record = try await refreshedRecord(existing)
    guard record.isSelectable else {
      if record.availability == .needsReview {
        throw ServiceAgentRegistryError.installationNeedsReview(installationID)
      }
      throw ServiceAgentRegistryError.installationUnavailable(installationID)
    }
    return record
  }

  public func models(
    installationID: AgentInstallationID,
    projectRoot: String? = nil,
    selectedModelID: String? = nil
  ) async throws -> [AgentModelDescriptor] {
    let record = try await validateForExecution(installationID: installationID)
    let provider = try provider(for: record.providerID)
    let installation = try AgentInstallation(
      id: record.id,
      providerID: record.providerID,
      executablePath: record.executableIdentity.canonicalPath,
      version: record.version,
      protocolRevision: record.protocolRevision,
      artifacts: record.artifacts.map { artifact in
        AgentInstallationArtifact(
          role: artifact.role,
          canonicalPath: artifact.identity.canonicalPath,
          device: artifact.identity.device,
          inode: artifact.identity.inode,
          fileSize: artifact.identity.fileSize,
          modificationTimeNanoseconds: artifact.identity.modificationTimeNanoseconds,
          sha256: artifact.identity.sha256
        )
      }
    )
    return try await provider.models(
      installation: installation,
      projectRoot: projectRoot,
      selectedModelID: selectedModelID
    )
  }

  @discardableResult
  public func refreshInstallationStates() async throws -> [ServiceAgentInstallationRecord] {
    let records = try await store.agentInstallations()
    var refreshed: [ServiceAgentInstallationRecord] = []
    refreshed.reserveCapacity(records.count)
    for record in records {
      let updated = try await refreshedRecord(record)
      refreshed.append(updated)
    }
    return refreshed
  }

  func refreshedRecord(_ record: ServiceAgentInstallationRecord) async throws
    -> ServiceAgentInstallationRecord
  {
    guard let provider = providers[record.providerID] else {
      return try await persistStateIfNeeded(
        record,
        availability: .unavailable,
        reason: "The Provider adapter is unavailable."
      )
    }
    let current: ServiceAgentExecutableIdentity
    do {
      current = try captureIdentity(record.executablePath)
    } catch {
      return try await persistStateIfNeeded(
        record,
        availability: .unavailable,
        reason: "The registered executable is unavailable."
      )
    }
    guard current.hasSameContent(as: record.executableIdentity) else {
      return try await persistStateIfNeeded(
        record,
        availability: .needsReview,
        reason: "The registered executable changed and requires local review."
      )
    }
    let currentArtifacts: [ServiceAgentInstallationArtifact]
    do {
      currentArtifacts = try captureArtifacts(record.artifacts, at: now())
      guard artifactsHaveSameContent(currentArtifacts, record.artifacts) else {
        return try await persistStateIfNeeded(
          record,
          availability: .needsReview,
          reason: "A registered installation artifact changed and requires local review."
        )
      }
    } catch {
      return try await persistStateIfNeeded(
        record,
        availability: .needsReview,
        reason: "A registered installation artifact is unavailable and requires local review."
      )
    }
    if record.availability == .unavailable,
      !record.isEnabled || now().timeIntervalSince(record.updatedAt) < 30
    {
      return record
    }
    let metadataChanged =
      current != record.executableIdentity
      || !artifactsHaveSameIdentity(currentArtifacts, record.artifacts)
    if provider.descriptor.adapterRevision != record.adapterRevision
      || metadataChanged || record.hasRecoverableIdentityReview
      || (record.isEnabled && record.availability == .unavailable)
    {
      return try await refreshProbe(
        record, provider: provider, identity: current, artifacts: currentArtifacts)
    }
    return record
  }

  func persistStateIfNeeded(
    _ record: ServiceAgentInstallationRecord,
    availability: ServiceAgentInstallationAvailability,
    reason: String
  ) async throws -> ServiceAgentInstallationRecord {
    if record.availability == availability,
      record.capabilities == .empty,
      record.lastProbeError == reason
    {
      return record
    }
    let updated = try unavailableRecord(
      record,
      availability: availability,
      identity: record.executableIdentity,
      reason: reason,
      probedAt: record.lastProbedAt,
      updatedAt: now()
    )
    try await store.updateAgentInstallation(updated, expectedRecord: record)
    guard let current = try await store.agentInstallation(id: record.id) else {
      throw ServiceStoreError.unknownAgentInstallation(record.id)
    }
    return current
  }
}
