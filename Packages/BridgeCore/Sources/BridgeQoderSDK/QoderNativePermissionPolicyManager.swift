import BridgeAgentCore
import BridgeSecurity
import Foundation

public actor QoderNativePermissionPolicyManager: AgentNativePermissionPolicyManaging {
  private let homeDirectory: String?
  private let cnConfigurationDirectory: String?
  private let internationalConfigurationDirectory: String?
  private let distributionResolver:
    (@Sendable (AgentInstallation) async throws -> QoderDistribution)?

  public init(
    sourceEnvironment: [String: String] = ToolDiscoveryEnvironment.current(),
    distributionResolver: (@Sendable (AgentInstallation) async throws -> QoderDistribution)? = nil
  ) {
    homeDirectory = try? AgentProviderEnvironment.homeDirectory(source: sourceEnvironment)
    cnConfigurationDirectory = sourceEnvironment["QODERCN_CONFIG_DIR"]
    internationalConfigurationDirectory = sourceEnvironment["QODER_CONFIG_DIR"]
    self.distributionResolver = distributionResolver
  }

  public func snapshot(
    installation: AgentInstallation
  ) async throws -> AgentNativePermissionPolicySnapshot {
    let distribution = try await distribution(for: installation)
    let store = try QoderNativePermissionSettingsStore(
      directory: settingsDirectory(for: distribution)
    )
    let loaded = try store.load()
    return try loaded.document.snapshot(
      installation: installation,
      distribution: distribution,
      revision: loaded.revision?.sha256
    )
  }

  public func update(
    installation: AgentInstallation,
    mutation: AgentNativePermissionMutation,
    expectedRevision: String?
  ) async throws -> AgentNativePermissionPolicySnapshot {
    let distribution = try await distribution(for: installation)
    let store = try QoderNativePermissionSettingsStore(
      directory: settingsDirectory(for: distribution)
    )
    let loaded = try store.load()
    guard loaded.revision?.sha256 == expectedRevision else {
      throw AgentNativePermissionPolicyError.revisionConflict
    }
    var document = loaded.document
    try document.apply(mutation)
    let revision = try store.save(document, expectedRevision: loaded.revision)
    return try document.snapshot(
      installation: installation,
      distribution: distribution,
      revision: revision.sha256
    )
  }

  public func remediation(
    toolName _: String,
    toolArguments _: String
  ) async -> AgentNativePermissionRemediation? {
    nil
  }

  private func distribution(for installation: AgentInstallation) async throws -> QoderDistribution {
    guard installation.providerID == .qoder else {
      throw AgentNativePermissionPolicyError.unavailable
    }
    let detected = QoderDistribution.identify(executablePath: installation.executablePath)
    let distribution: QoderDistribution
    if let distributionResolver {
      distribution = try await distributionResolver(installation)
      guard detected == nil || detected == distribution else {
        throw AgentNativePermissionPolicyError.unavailable
      }
    } else if let detected {
      distribution = detected
    } else {
      throw AgentNativePermissionPolicyError.unavailable
    }
    return distribution
  }

  private func settingsDirectory(for distribution: QoderDistribution) throws -> String {
    let configured =
      distribution == .cn
      ? cnConfigurationDirectory
      : internationalConfigurationDirectory
    if let configured {
      guard AgentPathSemantics.isAbsolute(configured), !configured.contains("\0") else {
        throw AgentNativePermissionPolicyError.settingsUnsafe
      }
      return configured
    }
    guard let homeDirectory else { throw AgentNativePermissionPolicyError.unavailable }
    let directory = distribution == .cn ? ".qoder-cn" : ".qoder"
    return URL(fileURLWithPath: homeDirectory, isDirectory: true)
      .appendingPathComponent(directory, isDirectory: true).path
  }
}
