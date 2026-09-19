import BridgeAgentCore
import Foundation

extension ServiceAgentRegistry {
  func refreshProbe(
    _ record: ServiceAgentInstallationRecord,
    provider: any AgentProvider,
    identity: ServiceAgentExecutableIdentity,
    artifacts: [ServiceAgentInstallationArtifact],
    executablePath: String
  ) async throws -> ServiceAgentInstallationRecord {
    if let pending = refreshProbes[record.id] {
      return try await pending.value
    }
    let pending = Task {
      let probed = try await self.probeRecord(
        id: record.id,
        provider: provider,
        displayName: record.displayName,
        executablePath: executablePath,
        identity: identity,
        trustProfile: record.trustProfile,
        securityProfileID: record.securityProfileID,
        isEnabled: record.isEnabled,
        projectRoot: nil,
        artifacts: artifacts,
        createdAt: record.createdAt
      )
      let updated =
        probed.availability == .available
        ? probed
        : try self.unavailableRecord(
          record,
          availability: probed.availability,
          identity: record.executableIdentity,
          reason: probed.lastProbeError ?? "The Agent did not pass the connection Probe.",
          probedAt: probed.lastProbedAt,
          updatedAt: probed.updatedAt
        )
      // A local edit or disconnect made during Probe takes precedence.
      try await self.store.updateAgentInstallation(
        updated, allowExecutableReplacement: true, expectedRecord: record)
      guard let current = try await self.store.agentInstallation(id: record.id) else {
        throw ServiceStoreError.unknownAgentInstallation(record.id)
      }
      return current
    }
    refreshProbes[record.id] = pending
    defer { refreshProbes[record.id] = nil }
    return try await pending.value
  }

  func artifactsHaveSameContent(
    _ first: [ServiceAgentInstallationArtifact],
    _ second: [ServiceAgentInstallationArtifact]
  ) -> Bool {
    guard first.count == second.count else { return false }
    let secondByRole = Dictionary(uniqueKeysWithValues: second.map { ($0.role, $0.identity) })
    return first.allSatisfy { artifact in
      guard let other = secondByRole[artifact.role] else { return false }
      return artifact.identity.hasSameContent(as: other)
    }
  }
}

extension ServiceAgentExecutableIdentity {
  func hasSameContent(as other: Self) -> Bool {
    AgentPathSemantics.relativePath(canonicalPath, from: other.canonicalPath) == ""
      && fileSize == other.fileSize && sha256 == other.sha256
  }
}

extension ServiceAgentFileIdentity {
  func hasSameContent(as other: Self) -> Bool {
    AgentPathSemantics.relativePath(canonicalPath, from: other.canonicalPath) == ""
      && fileSize == other.fileSize && sha256 == other.sha256
  }
}

extension ServiceAgentInstallationRecord {
  var hasRecoverableIdentityReview: Bool {
    guard availability == .needsReview else { return false }
    return lastProbeError == "The Provider adapter changed and requires a new Probe."
      || lastProbeError == "The registered executable changed and requires local review."
      || lastProbeError == "A registered installation artifact changed and requires local review."
      || lastProbeError
        == "A registered installation artifact is unavailable and requires local review."
  }
}
