import BridgeAgentCore
import BridgeMCP
import BridgeServiceCore
import Foundation

public enum ServiceAgentConnectionError: Error, LocalizedError, Sendable {
  case installationNotFound
  case headlessPermissionConfirmationRequired

  public var errorDescription: String? {
    switch self {
    case .installationNotFound:
      "未找到本机 Agent，请确认已安装对应的命令行程序。"
    case .headlessPermissionConfirmationRequired:
      "AGY 无头任务需要自动通过工具执行，请先同意将本机 AGY 全局工具策略设为 Always Proceed（总是通过）。"
    }
  }
}

extension BridgeServiceApplication {
  public func serviceConnectManagedAgent(
    providerID: AgentProviderID,
    baseURL: String?,
    apiKey: String?,
    candidates: [ServiceAgentRegistrationRequest],
    alwaysProceedConfirmed: Bool = false,
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceAgentInstallationRecord {
    try Self.checkDeadline(deadline)
    let registry = try requiredAgentRegistry()
    try requireHeadlessPermissionConfirmation(
      providerID: providerID,
      confirmed: alwaysProceedConfirmed
    )
    let matchingCandidates = candidates.filter { $0.providerID == providerID }
    guard !matchingCandidates.isEmpty else {
      throw ServiceAgentConnectionError.installationNotFound
    }
    try validateConnectionCandidates(matchingCandidates, providerID: providerID)

    var lastRecord: ServiceAgentInstallationRecord?
    var lastError: (any Error)?
    for candidate in matchingCandidates {
      try Self.checkDeadline(deadline)
      do {
        try await configureConnectionCredentials(candidate, baseURL: baseURL, apiKey: apiKey)
        let record = try await registry.connect(candidate)
        if record.availability == .available {
          do {
            try await ensureHeadlessPermission(
              providerID: providerID,
              installationID: record.id,
              registry: registry,
              deadline: deadline
            )
          } catch {
            _ = try? await registry.setEnabled(false, installationID: record.id)
            throw error
          }
          return record
        }
        lastRecord = record
      } catch {
        lastError = error
      }
    }
    if let lastRecord { return lastRecord }
    if let lastError { throw lastError }
    throw ServiceAgentConnectionError.installationNotFound
  }

  private func requireHeadlessPermissionConfirmation(
    providerID: AgentProviderID,
    confirmed: Bool
  ) throws {
    guard
      ServiceAgentProviderPolicyRegistry.policy(for: providerID)?.requiresHeadlessAlwaysProceed
        == true
    else { return }
    guard confirmed else {
      throw ServiceAgentConnectionError.headlessPermissionConfirmationRequired
    }
  }

  private func ensureHeadlessPermission(
    providerID: AgentProviderID,
    installationID: AgentInstallationID,
    registry: ServiceAgentRegistry,
    deadline: ContinuousClock.Instant
  ) async throws {
    guard
      ServiceAgentProviderPolicyRegistry.policy(for: providerID)?.requiresHeadlessAlwaysProceed
        == true
    else { return }
    try Self.checkDeadline(deadline)
    let current = try await registry.nativePermissionPolicy(installationID: installationID)
    guard current.toolPermission != "always-proceed" else { return }
    _ = try await registry.updateNativePermissionPolicy(
      installationID: installationID,
      mutation: .setToolPermission("always-proceed"),
      expectedRevision: current.revision
    )
    try Self.checkDeadline(deadline)
  }

  private func configureConnectionCredentials(
    _ candidate: ServiceAgentRegistrationRequest,
    baseURL: String?,
    apiKey: String?
  ) async throws {
    guard baseURL != nil || apiKey != nil else { return }
    guard candidate.providerID == .deepSeekHarness else {
      throw ServiceAgentCredentialError.unsupportedProvider(candidate.providerID)
    }
    guard let baseURL else { throw ServiceAgentCredentialError.invalidBaseURL }
    guard let apiKey else { throw ServiceAgentCredentialError.invalidAPIKey }
    guard let configurationPath = candidate.configurationPath, let agentCredentials else {
      throw ServiceAgentCredentialError.invalidConfigurationPath
    }
    try await agentCredentials.configureDeepSeekHarness(
      baseURL: baseURL,
      apiKey: apiKey,
      configurationPath: configurationPath
    )
    let normalizedBaseURL = await agentCredentials.configuredDeepSeekBaseURL(for: configurationPath)
    try await settings.set(normalizedBaseURL, for: .deepSeekHarnessBaseURL)
    try await settings.set(configurationPath, for: .deepSeekHarnessManagedConfigurationPath)
  }

  private func validateConnectionCandidates(
    _ candidates: [ServiceAgentRegistrationRequest],
    providerID: AgentProviderID
  ) throws {
    guard let policy = ServiceAgentProviderPolicyRegistry.policy(for: providerID) else {
      throw BridgeMCPQueryError.contractRejected
    }
    for candidate in candidates {
      guard !policy.requiresConfiguration || candidate.configurationPath != nil,
        !policy.requiresExactRegistrationProfile
          || (candidate.trustProfile == policy.registrationTrustProfile
            && candidate.securityProfileID == policy.registrationSecurityProfileID
            && Set(candidate.artifactRequests.map(\.role)) == policy.requiredArtifactRoles)
      else {
        throw BridgeMCPQueryError.contractRejected
      }
    }
  }
}
