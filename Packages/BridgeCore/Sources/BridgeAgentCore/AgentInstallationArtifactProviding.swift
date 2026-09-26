import Foundation

/// Runtime files resolved before a Probe and frozen with the installation.
public protocol AgentInstallationArtifactProviding: Sendable {
  func installationArtifacts(for installation: AgentInstallation) async throws
    -> [AgentInstallationArtifact]
}
