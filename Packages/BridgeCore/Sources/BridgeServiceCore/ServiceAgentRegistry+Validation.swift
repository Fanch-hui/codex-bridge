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
      do {
        refreshed.append(try await refreshedRecord(record))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // A single installation can disappear or fail while its siblings remain
        // usable. Keep its last snapshot for this refresh and retry later.
        refreshed.append(record)
      }
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
    if record.availability == .unavailable,
      !record.isEnabled || now().timeIntervalSince(record.updatedAt) < 30
    {
      return record
    }
    if record.availability == .needsReview, !record.hasRecoverableIdentityReview,
      record.lastProbedAt == record.updatedAt,
      now().timeIntervalSince(record.updatedAt) < 30
    {
      return record
    }
    let candidate: RefreshCandidate
    do {
      candidate = try refreshCandidate(record)
    } catch {
      return try await persistStateIfNeeded(
        record,
        availability: .unavailable,
        reason: "The registered executable or installation runtime is unavailable."
      )
    }
    let current = candidate.identity
    let currentArtifacts = candidate.artifacts
    guard launchConfigurationUnchanged(candidate, from: record) else {
      return try await persistStateIfNeeded(
        record,
        availability: .needsReview,
        reason: "A registered installation artifact changed and requires local review."
      )
    }
    let contentChanged =
      !current.hasSameContent(as: record.executableIdentity)
      || !artifactsHaveSameContent(currentArtifacts, record.artifacts)
    if contentChanged, !record.isEnabled {
      return try await persistStateIfNeeded(
        record,
        availability: .needsReview,
        reason: "The registered executable changed and requires local review."
      )
    }
    let metadataChanged =
      current != record.executableIdentity
      || !artifactsHaveSameIdentity(currentArtifacts, record.artifacts)
    if provider.descriptor.adapterRevision != record.adapterRevision
      || metadataChanged || contentChanged || record.hasRecoverableIdentityReview
      || (record.isEnabled && record.availability == .unavailable)
    {
      return try await refreshProbe(
        record, provider: provider, identity: current, artifacts: currentArtifacts,
        executablePath: candidate.executablePath)
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
