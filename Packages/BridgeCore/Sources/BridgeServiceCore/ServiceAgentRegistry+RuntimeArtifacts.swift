import BridgeAgentCore
import Foundation

extension ServiceAgentRegistry {
  func runtimeArtifacts(
    provider: any AgentProvider,
    installationID: AgentInstallationID,
    executablePath: String,
    existing: [ServiceAgentInstallationArtifact],
    at date: Date
  ) async throws -> [ServiceAgentInstallationArtifact] {
    guard let resolver = provider as? any AgentInstallationArtifactProviding else {
      return existing
    }
    let installation = try AgentInstallation(
      id: installationID, providerID: provider.descriptor.providerID,
      executablePath: executablePath
    )
    let snapshots = try await resolver.installationArtifacts(for: installation)
    _ = try AgentInstallation(
      id: installationID, providerID: provider.descriptor.providerID,
      executablePath: executablePath, artifacts: snapshots
    )
    return try snapshots.map { snapshot in
      let identity = try captureArtifactIdentity(
        snapshot.canonicalPath, snapshot.role.requiresExecutable
      )
      guard identity.sha256 == snapshot.sha256,
        identity.fileSize == snapshot.fileSize,
        identity.inode == snapshot.inode,
        identity.device == snapshot.device,
        identity.modificationTimeNanoseconds == snapshot.modificationTimeNanoseconds
      else { throw ServiceStoreError.invalidArgument("agentInstallation.runtimeArtifactChanged") }
      return try ServiceAgentInstallationArtifact(
        role: snapshot.role, identity: identity,
        createdAt: existing.first(where: { $0.role == snapshot.role })?.createdAt ?? date,
        updatedAt: date
      )
    }
  }
}
