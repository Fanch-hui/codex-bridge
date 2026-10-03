import BridgeAgentCore
import Foundation

extension ServiceAgentRegistry {
  func archiveArtifacts(
    provider: any AgentProvider, installationID: AgentInstallationID,
    executablePath: String
  ) async throws -> [AgentInstallationRuntimeArtifact] {
    guard let resolver = provider as? any AgentInstallationRuntimeArtifactProviding else {
      return []
    }
    let installation = try AgentInstallation(
      id: installationID,
      providerID: provider.descriptor.providerID, executablePath: executablePath)
    let artifacts = try await resolver.installationRuntimeArtifacts(for: installation)
    try AgentInstallationRuntimeArtifact.validate(artifacts)
    guard try captureArchiveArtifacts(artifacts) == artifacts else {
      throw ServiceStoreError.invalidArgument("agentInstallation.runtimeArtifactChanged")
    }
    return artifacts
  }

  func captureArchiveArtifacts(_ artifacts: [AgentInstallationRuntimeArtifact]) throws
    -> [AgentInstallationRuntimeArtifact]
  {
    try artifacts.map { artifact in
      let identity = try captureArtifactIdentity(artifact.canonicalPath, false)
      return AgentInstallationRuntimeArtifact(
        role: artifact.role,
        canonicalPath: identity.canonicalPath, device: identity.device, inode: identity.inode,
        fileSize: identity.fileSize,
        modificationTimeNanoseconds: identity.modificationTimeNanoseconds,
        sha256: identity.sha256)
    }
  }

  func archivesHaveSameContent(
    _ first: [AgentInstallationRuntimeArtifact],
    _ second: [AgentInstallationRuntimeArtifact]
  ) -> Bool {
    guard first.count == second.count else { return false }
    let byPath = Dictionary(uniqueKeysWithValues: second.map { ($0.canonicalPath, $0) })
    return first.allSatisfy { value in
      guard let other = byPath[value.canonicalPath] else { return false }
      return value.role == other.role && value.fileSize == other.fileSize
        && value.sha256 == other.sha256
    }
  }
}
