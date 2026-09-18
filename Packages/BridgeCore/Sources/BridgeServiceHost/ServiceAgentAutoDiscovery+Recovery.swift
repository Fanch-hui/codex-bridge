import BridgeAgentCore
import BridgeServiceCore
import Foundation

extension ServiceAgentAutoDiscovery {
  /// Resolves a replacement for an enabled installation after an update moved
  /// its executable or one of its runtime artifacts. This only inspects the
  /// filesystem; the Registry owns Probe and persistence.
  static func updatedInstallationRequest(
    for existing: ServiceAgentInstallationRecord,
    dataPaths: ServiceDataPaths,
    environment: [String: String]
  ) throws -> ServiceAgentRegistrationRequest? {
    let candidates =
      (try? registrationRequests(
        providerID: existing.providerID,
        dataPaths: dataPaths,
        existingInstallations: [existing],
        environment: environment,
        allowGeneratedConfiguration: false
      )) ?? []
    let matches = candidates.filter { candidate in
      candidate.providerID == existing.providerID
        && candidate.trustProfile == existing.trustProfile
        && candidate.securityProfileID == existing.securityProfileID
        && preservesArtifactLayout(candidate, for: existing)
    }
    guard matches.count == 1, let candidate = matches.first else { return nil }
    return try ServiceAgentRegistrationRequest(
      providerID: existing.providerID,
      displayName: existing.displayName,
      executablePath: candidate.executablePath,
      trustProfile: existing.trustProfile,
      securityProfileID: existing.securityProfileID,
      enableOnSuccess: false,
      configurationPath: candidate.configurationPath,
      artifacts: candidate.artifacts
    )
  }

  private static func preservesArtifactLayout(
    _ candidate: ServiceAgentRegistrationRequest,
    for existing: ServiceAgentInstallationRecord
  ) -> Bool {
    let existingConfiguration = existing.artifacts.first {
      $0.role == .launchConfiguration
    }?.canonicalPath
    guard samePath(candidate.configurationPath, existingConfiguration) else { return false }

    let existingRoles = Set(
      existing.artifacts.compactMap { artifact in
        artifact.role == .launchConfiguration ? nil : artifact.role
      }
    )
    return Set(candidate.artifacts.map(\.role)) == existingRoles
  }

  private static func samePath(_ first: String?, _ second: String?) -> Bool {
    switch (first, second) {
    case (nil, nil): return true
    case (let first?, let second?): return pathKey(first) == pathKey(second)
    default: return false
    }
  }
}
