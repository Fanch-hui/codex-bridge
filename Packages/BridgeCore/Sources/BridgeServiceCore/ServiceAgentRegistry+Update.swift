import BridgeAgentCore
import Foundation

extension ServiceAgentRegistry {
  struct RefreshCandidate {
    let executablePath: String
    let identity: ServiceAgentExecutableIdentity
    let artifacts: [ServiceAgentInstallationArtifact]
  }

  func refreshCandidate(_ record: ServiceAgentInstallationRecord) throws -> RefreshCandidate {
    let current = Result {
      try RefreshCandidate(
        executablePath: record.executablePath,
        identity: captureIdentity(record.executablePath),
        artifacts: captureArtifacts(record.artifacts, at: now())
      )
    }
    guard record.isEnabled else { return try current.get() }
    if case .success(let candidate) = current,
      candidate.identity.hasSameContent(as: record.executableIdentity),
      artifactsHaveSameContent(candidate.artifacts, record.artifacts)
    {
      return candidate
    }
    guard let request = try resolveUpdatedInstallation(record),
      request.providerID == record.providerID,
      request.trustProfile == record.trustProfile,
      request.securityProfileID == record.securityProfileID
    else { return try current.get() }
    return RefreshCandidate(
      executablePath: request.executablePath,
      identity: try captureIdentity(request.executablePath),
      artifacts: try captureArtifacts(request.artifactRequests, at: now())
    )
  }

  func launchConfigurationUnchanged(
    _ candidate: RefreshCandidate, from record: ServiceAgentInstallationRecord
  ) -> Bool {
    artifactsHaveSameContent(
      candidate.artifacts.filter { $0.role == .launchConfiguration },
      record.artifacts.filter { $0.role == .launchConfiguration }
    )
  }
}
