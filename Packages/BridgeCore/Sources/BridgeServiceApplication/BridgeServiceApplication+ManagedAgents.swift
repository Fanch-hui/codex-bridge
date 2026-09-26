import BridgeAgentCore
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public func serviceManagedAgentProviderDescriptors(
    deadline: ContinuousClock.Instant
  ) async throws -> [AgentProviderDescriptor] {
    try Self.checkDeadline(deadline)
    return try await requiredAgentRegistry().providerDescriptors()
  }

  public func serviceDeepSeekHarnessBaseURL(
    deadline: ContinuousClock.Instant
  ) async throws -> String? {
    try Self.checkDeadline(deadline)
    return try await settings.string(for: .deepSeekHarnessBaseURL)
  }

  public func serviceManagedAgentInstallations(
    deadline: ContinuousClock.Instant
  ) async throws -> [ServiceAgentInstallationRecord] {
    try Self.checkDeadline(deadline)
    return try await requiredAgentRegistry().installations()
  }

  public func serviceRegisterManagedAgent(
    _ request: ServiceAgentRegistrationRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceAgentInstallationRecord {
    try Self.checkDeadline(deadline)
    if let policy = ServiceAgentProviderPolicyRegistry.policy(for: request.providerID),
      policy.requiresConfiguration,
      request.configurationPath == nil,
      !request.artifacts.contains(where: { $0.role == .launchConfiguration })
    {
      throw BridgeMCPQueryError.contractRejected
    }
    if let policy = ServiceAgentProviderPolicyRegistry.policy(for: request.providerID),
      policy.requiresExactRegistrationProfile
    {
      guard request.trustProfile == policy.registrationTrustProfile,
        request.securityProfileID == policy.registrationSecurityProfileID,
        Set(request.artifactRequests.map(\.role)) == policy.requiredArtifactRoles
      else {
        throw BridgeMCPQueryError.contractRejected
      }
    }
    let record = try await requiredAgentRegistry().registerAndProbe(request)
    try Self.checkDeadline(deadline)
    return record
  }

  public func serviceReprobeManagedAgent(
    installationID: AgentInstallationID,
    acceptReplacement: Bool,
    replacementRequest: ServiceAgentRegistrationRequest? = nil,
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceAgentInstallationRecord {
    try Self.checkDeadline(deadline)
    let registry = try requiredAgentRegistry()
    let record: ServiceAgentInstallationRecord
    if acceptReplacement, let replacementRequest {
      record = try await registry.replaceAndProbe(
        installationID: installationID, request: replacementRequest)
    } else {
      record = try await registry.reprobe(
        installationID: installationID, acceptReplacement: acceptReplacement)
    }
    try Self.checkDeadline(deadline)
    return record
  }

  public func serviceSetManagedAgentEnabled(
    installationID: AgentInstallationID,
    enabled: Bool,
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceAgentInstallationRecord {
    try Self.checkDeadline(deadline)
    let record = try await requiredAgentRegistry().setEnabled(
      enabled,
      installationID: installationID
    )
    if record.providerID == .qoder,
      let distribution = try await qoderDistribution(for: record)
    {
      try await settings.setQoderInstallationDistribution(
        installationID: record.id.rawValue, distribution: distribution)
      let current = try await settings.qoderRuntimeSettings(distribution: distribution)
      let activeID =
        enabled
        ? record.id.rawValue
        : (current.activeInstallationID == record.id.rawValue ? nil : current.activeInstallationID)
      let updated = ServiceQoderRuntimeSettings(
        distribution: distribution,
        activeInstallationID: activeID,
        nodeExecutablePath: current.nodeExecutablePath,
        sdkRoot: current.sdkRoot
      )
      if enabled {
        try await settings.setQoderRuntimeSettings(updated)
      } else {
        try await settings.setQoderRegionSettings(updated)
      }
    }
    try Self.checkDeadline(deadline)
    return record
  }

  public func serviceRemoveManagedAgent(
    installationID: AgentInstallationID,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    let registry = try requiredAgentRegistry()
    let existing = try await registry.installation(id: installationID)
    try await registry.remove(installationID: installationID)
    if let existing, existing.providerID == .qoder,
      let distribution = try await qoderDistribution(for: existing)
    {
      let current = try await settings.qoderRuntimeSettings(distribution: distribution)
      if current.activeInstallationID == existing.id.rawValue {
        try await settings.setQoderRegionSettings(
          ServiceQoderRuntimeSettings(
            distribution: distribution,
            activeInstallationID: nil,
            nodeExecutablePath: current.nodeExecutablePath,
            sdkRoot: current.sdkRoot
          )
        )
      }
    }
  }

  func requiredAgentRegistry() throws -> ServiceAgentRegistry {
    guard let agentRegistry else { throw BridgeMCPQueryError.unavailable }
    return agentRegistry
  }
}

extension BridgeServiceApplication {
  /// Local App submission path for agent providers. The desktop app is the
  /// local user surface, so its task starts immediately without MCP approval.
  public func serviceSubmitAgentTask(
    projectID: String,
    providerID: String,
    installationID: String?,
    model: String?,
    effort: String? = nil,
    permissionMode: String? = nil,
    networkAccess: Bool = false,
    prompt: String,
    threadID: String? = nil,
    skillName: String? = nil,
    skillNames: [String]? = nil,
    modelOverride: Bool? = nil,
    permissionModeOverride: Bool? = nil,
    acceptanceCriteria: [String] = [],
    clientRequestID: String? = nil,
    queueIfBusy: Bool = false,
    attachmentPaths: [String]? = nil,
    attachmentSourceTaskID: String? = nil,
    deadline: ContinuousClock.Instant
  ) async throws -> (taskID: String, status: String) {
    try Self.checkDeadline(deadline)
    let submission = MCPServiceTaskSubmission(
      projectID: projectID,
      prompt: prompt,
      skillName: skillName,
      skillNames: skillNames,
      threadID: threadID,
      providerID: providerID,
      installationID: installationID,
      executionModel: model,
      executionEffort: effort,
      modelOverride: modelOverride ?? (model != nil || effort != nil ? true : nil),
      permissionMode: permissionMode,
      permissionModeOverride: permissionModeOverride,
      networkAccess: networkAccess,
      acceptanceCriteria: acceptanceCriteria,
      clientRequestID: clientRequestID ?? "app-\(UUID().uuidString.lowercased())",
      queueIfBusy: queueIfBusy,
      attachmentPaths: attachmentPaths,
      attachmentSourceTaskID: attachmentSourceTaskID
    )
    let receipt = try await serviceSubmitTaskFromLocalApp(
      submission,
      deadline: deadline
    )
    return (receipt.taskID, receipt.status)
  }
}

public struct ServiceAgentModelListItem: Codable, Equatable, Sendable {
  public let modelID: String
  public let displayName: String
  public let supportedReasoningEfforts: [String]
  public let defaultReasoningEffort: String?
  public let reasoningCapabilitiesAvailable: Bool
  public let isDefaultModel: Bool?

  public init(
    modelID: String,
    displayName: String,
    supportedReasoningEfforts: [String] = [],
    defaultReasoningEffort: String? = nil,
    reasoningCapabilitiesAvailable: Bool = true,
    isDefaultModel: Bool? = nil
  ) {
    self.modelID = modelID
    self.displayName = displayName
    self.supportedReasoningEfforts = supportedReasoningEfforts
    self.defaultReasoningEffort = defaultReasoningEffort
    self.reasoningCapabilitiesAvailable = reasoningCapabilitiesAvailable
    self.isDefaultModel = isDefaultModel
  }
}

extension BridgeServiceApplication {
  /// Lists models advertised by the registered provider binary itself
  /// (config providers plus subscription catalogs such as Go/Zen).
  public func serviceListAgentModels(
    installationID: AgentInstallationID,
    projectID: String? = nil,
    modelID: String? = nil,
    useStoredDefault: Bool = true,
    forceRefresh: Bool = false,
    deadline: ContinuousClock.Instant
  ) async throws -> [ServiceAgentModelListItem] {
    try Self.checkDeadline(deadline)
    let registry = try requiredAgentRegistry()
    guard let installation = try await registry.installation(id: installationID) else {
      throw BridgeMCPQueryError.unavailable
    }
    guard installation.capabilities.effective.contains(.modelSelection) else {
      return []
    }
    let projectRoot = try await agentModelProjectRoot(
      projectID: projectID,
      deadline: deadline
    )
    try Self.checkDeadline(deadline)
    let selectedModelID: String?
    if let modelID {
      selectedModelID = modelID
    } else if useStoredDefault {
      guard let installation = try await registry.installation(id: installationID) else {
        throw BridgeMCPQueryError.unavailable
      }
      selectedModelID = try await serviceAgentModelDefault(
        providerID: installation.providerID,
        deadline: deadline
      ).model
    } else {
      selectedModelID = nil
    }
    let models = try await serviceAgentModelCatalog(
      registry: registry,
      installationID: installationID,
      projectRoot: projectRoot,
      selectedModelID: selectedModelID,
      forceRefresh: forceRefresh,
      requireSelectedModel: modelID != nil
    )
    try Self.checkDeadline(deadline)
    return models.map {
      ServiceAgentModelListItem(
        modelID: $0.id,
        displayName: $0.displayName,
        supportedReasoningEfforts: $0.supportedReasoningEfforts,
        defaultReasoningEffort: $0.defaultReasoningEffort,
        reasoningCapabilitiesAvailable: $0.reasoningCapabilitiesAvailable,
        isDefaultModel: $0.isDefaultModel
      )
    }
  }

  func serviceAgentModelCatalog(
    registry: ServiceAgentRegistry,
    installationID: AgentInstallationID,
    projectRoot: String?,
    selectedModelID: String?,
    forceRefresh: Bool = false,
    requireSelectedModel: Bool = true
  ) async throws -> [AgentModelDescriptor] {
    guard try await registry.installation(id: installationID) != nil else {
      throw BridgeMCPQueryError.unavailable
    }
    return try await registry.models(
      installationID: installationID,
      projectRoot: projectRoot,
      selectedModelID: selectedModelID,
      forceRefresh: forceRefresh,
      requireSelectedModel: requireSelectedModel
    )
  }

  private func agentModelProjectRoot(
    projectID: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> String? {
    let selectedID: String?
    if let projectID {
      selectedID = projectID
    } else {
      selectedID = try await serviceWorkbenchProjectID(deadline: deadline)
    }
    guard let selectedID, !selectedID.isEmpty else { return nil }
    try Self.checkDeadline(deadline)
    return try await readableProject(selectedID).root.canonicalPath
  }
}

extension BridgeServiceApplication {
  public func serviceAgentModelDefault(
    providerID: AgentProviderID,
    deadline: ContinuousClock.Instant
  ) async throws -> (model: String?, permissionMode: String, effort: String?) {
    try Self.checkDeadline(deadline)
    let descriptor = try await agentDefaultSettings(providerID: providerID, deadline: deadline)
    return try await agentModelDefaults(providerID: providerID, descriptor: descriptor)
  }

  private func agentModelDefaults(
    providerID: AgentProviderID,
    descriptor: ServiceAgentDefaultSettings
  ) async throws -> (model: String?, permissionMode: String, effort: String?) {
    var model = try await settings.string(
      for: descriptor.modelKey
    )
    if providerID == .deepSeekHarness {
      model = try await migratedDeepSeekModelDefault(model)
    }
    let effort: String?
    if providerID == .antigravity {
      effort = nil
    } else {
      effort = try await settings.string(for: descriptor.effortKey)
    }
    let permissionMode = try await descriptor.permissionMode(from: settings)
    return (model, permissionMode, effort)
  }

  private func migratedDeepSeekModelDefault(_ model: String?) async throws -> String? {
    let prefix = "opencode-go/"
    guard let model, model.hasPrefix(prefix) else { return model }
    let wireModelID = String(model.dropFirst(prefix.count))
    let registry = try requiredAgentRegistry()
    guard
      let installation = try await registry.installations(providerID: .deepSeekHarness)
        .filter(\.isSelectable)
        .sorted(by: { $0.id.rawValue < $1.id.rawValue })
        .first,
      let catalog = try? await registry.models(
        installationID: installation.id,
        projectRoot: nil,
        selectedModelID: model
      ),
      !catalog.contains(where: { $0.id == model }),
      catalog.contains(where: { $0.id == wireModelID })
    else {
      return model
    }
    try await settings.set(wireModelID, for: .deepSeekHarnessDefaultModel)
    return wireModelID
  }

  public func serviceSetAgentModelDefault(
    providerID: AgentProviderID,
    model: String?,
    permissionMode: String?,
    effort: String?,
    updateEffort: Bool,
    deadline: ContinuousClock.Instant
  ) async throws -> (model: String?, permissionMode: String, effort: String?) {
    try Self.checkDeadline(deadline)
    guard let policy = ServiceAgentProviderPolicyRegistry.policy(for: providerID),
      policy.supportsModelSelection,
      policy.supportsEffortSelection || !updateEffort || effort == nil
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    let descriptor = try await agentDefaultSettings(providerID: providerID, deadline: deadline)
    let validated = try Self.validatedAgentModel(model)
    try await settings.set(validated, for: descriptor.modelKey)
    if let permissionMode {
      try await settings.set(
        descriptor.normalizedPermission(permissionMode), for: descriptor.permissionKey)
    }
    if providerID == .antigravity {
      try await settings.set(nil, for: .antigravityDefaultEffort)
    } else if updateEffort {
      if let effort {
        guard !effort.isEmpty, effort.utf8.count <= 64,
          !effort.contains("\0"),
          effort.rangeOfCharacter(from: .controlCharacters) == nil
        else { throw BridgeMCPQueryError.contractRejected }
      }
      try await settings.set(
        effort,
        for: descriptor.effortKey
      )
    }
    return try await agentModelDefaults(providerID: providerID, descriptor: descriptor)
  }

  public func serviceOpenCodeDefaultModel(
    deadline: ContinuousClock.Instant
  ) async throws -> String? {
    try Self.checkDeadline(deadline)
    return try await settings.string(for: .openCodeDefaultModel)
  }

  public func serviceSetOpenCodeDefaultModel(
    _ model: String?,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    let validated = try Self.validatedAgentModel(model)
    try await settings.set(validated, for: .openCodeDefaultModel)
  }

  public func serviceOpenCodeDefaultPermissionMode(
    deadline: ContinuousClock.Instant
  ) async throws -> String {
    try Self.checkDeadline(deadline)
    return try await settings.openCodeDefaultPermissionMode()
  }

  public func serviceSetOpenCodeDefaultPermissionMode(
    _ mode: String,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    try await settings.setOpenCodeDefaultPermissionMode(mode)
  }

  public func serviceOpenCodeDefaultEffort(
    deadline: ContinuousClock.Instant
  ) async throws -> String? {
    try Self.checkDeadline(deadline)
    return try await settings.openCodeDefaultEffort()
  }

  public func serviceSetOpenCodeDefaultEffort(
    _ effort: String?,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    try await settings.setOpenCodeDefaultEffort(effort)
  }

  static func agentDefaultModelKey(providerID: AgentProviderID) throws
    -> ServiceSettingKey
  {
    try ServiceAgentDefaultSettings.descriptor(for: providerID).modelKey
  }

  static func agentDefaultEffortKey(providerID: AgentProviderID) throws
    -> ServiceSettingKey
  {
    try ServiceAgentDefaultSettings.descriptor(for: providerID).effortKey
  }
}
