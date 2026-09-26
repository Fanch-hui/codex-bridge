import BridgeAgentCore
import BridgeDeepSeekHarnessACP
import BridgeIPC
import BridgeMCP
import BridgeServiceApplication
import BridgeServiceCore
import Foundation

extension BridgeServiceRequestController {
  func handleGetAgentCatalog(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let catalogRequest = try BridgeServiceIPCCodec.optionalPayload(
      IPCAgentCatalogRequest.self,
      from: request
    )
    let deadline = Self.deadline()
    let providers = try await composition.application.serviceManagedAgentProviderDescriptors(
      deadline: deadline
    )
    let installations = try await composition.application.serviceManagedAgentInstallations(
      deadline: deadline
    )
    _ = try await composition.application.serviceQoderRuntimeSettings(deadline: deadline)
    let qoderSnapshot = try await composition.settings.qoderRuntimeSettingsSnapshot()
    let selectedDistribution = qoderSnapshot.selectedDistribution ?? .cn
    let selectedQoderSettings = qoderSnapshot.regions[selectedDistribution]!
    let qoderRegionSettings = QoderDistribution.allCases.compactMap {
      qoderSnapshot.regions[$0]
    }
    let configuredDeepSeekBaseURL = try? await composition.application
      .serviceDeepSeekHarnessBaseURL(deadline: deadline)
    let installationDistributionsByPath = try await qoderDistributionsByExecutablePath(
      for: installations)
    var discovery = await composition.agentDiscoveryCatalog.summaries(
      providerIDs: providers.map(\.providerID),
      existingInstallations: installations,
      forceRefresh: catalogRequest?.forceRefresh ?? false
    )
    discovery[.qoder] = try ServiceAgentAutoDiscovery.discoverySummary(
      providerID: .qoder,
      existingInstallations: installations,
      environment: ToolDiscoveryEnvironment.current(),
      qoderDistribution: selectedQoderSettings.distribution,
      qoderDistributionsByExecutablePath: installationDistributionsByPath
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCAgentCatalogResponse(
        providers: providers.map { provider in
          Self.agentProviderSummary(
            provider,
            discovery: discovery[provider.providerID],
            configuredBaseURL: provider.providerID == .deepSeekHarness
              ? configuredDeepSeekBaseURL : nil,
            qoderDistribution: provider.providerID == .qoder
              ? selectedQoderSettings.distribution.rawValue : nil,
            qoderRegionSettings: provider.providerID == .qoder
              ? qoderRegionSettings.map(Self.qoderRegionSummary) : nil
          )
        },
        installations: installations.map { installation in
          let distribution = installationDistributionsByPath[installation.executablePath]
          let activeID = distribution.flatMap { region in
            qoderRegionSettings.first(where: { $0.distribution == region })?.activeInstallationID
          }
          return Self.agentInstallationSummary(
            installation,
            distribution: distribution?.rawValue,
            isActive: activeID == installation.id.rawValue
          )
        }
      )
    )
  }

  static func registrationArtifacts(
    providerID: AgentProviderID,
    executablePath: String,
    configurationPath: String?
  ) throws -> [ServiceAgentInstallationArtifactRequest] {
    guard providerID == .deepSeekHarness else { return [] }
    guard let configurationPath else {
      throw AgentRuntimeError.invalidRequest("registration.configurationPath")
    }
    let paths = try DeepSeekHarnessACPProfile.resolveArtifacts(
      executablePath: executablePath,
      configurationPath: configurationPath
    )
    return try AgentInstallationArtifactRole.allCases.compactMap { role in
      guard role != .launchConfiguration, let path = paths[role] else { return nil }
      return try ServiceAgentInstallationArtifactRequest(role: role, path: path)
    }
  }

  func handleReprobeAgentInstallation(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCAgentReprobeRequest.self,
      from: request
    )
    let replacement = try await deepSeekReplacementRequest(
      installationID: AgentInstallationID(rawValue: payload.installationID),
      acceptReplacement: payload.acceptReplacement
    )
    let record = try await composition.application.serviceReprobeManagedAgent(
      installationID: AgentInstallationID(rawValue: payload.installationID),
      acceptReplacement: payload.acceptReplacement,
      replacementRequest: replacement,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: Self.agentInstallationSummary(record)
    )
  }

  func handleSetAgentInstallationEnabled(
    _ request: BridgeServiceIPCRequest
  ) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCAgentEnabledRequest.self,
      from: request
    )
    let record = try await composition.application.serviceSetManagedAgentEnabled(
      installationID: AgentInstallationID(rawValue: payload.installationID),
      enabled: payload.enabled,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: Self.agentInstallationSummary(record)
    )
  }

  func handleRemoveAgentInstallation(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCAgentInstallationIDRequest.self,
      from: request
    )
    try await composition.application.serviceRemoveManagedAgent(
      installationID: AgentInstallationID(rawValue: payload.installationID),
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)
  }

  private static func agentProviderSummary(
    _ descriptor: AgentProviderDescriptor,
    discovery: ServiceAgentDiscoverySummary?,
    configuredBaseURL: String?,
    qoderDistribution: String?,
    qoderRegionSettings: [IPCAgentQoderRegionSettings]?
  ) -> IPCAgentProviderSummary {
    let policy = ServiceAgentProviderPolicyRegistry.policy(for: descriptor.providerID)
    return IPCAgentProviderSummary(
      providerID: descriptor.providerID.rawValue,
      displayName: descriptor.displayName,
      adapterRevision: descriptor.adapterRevision,
      discoveryState: discovery?.state,
      discoveryMessage: discovery?.message,
      discoveredExecutablePath: discovery?.executablePath,
      discoveredConfigurationPath: discovery?.configurationPath,
      configuredBaseURL: configuredBaseURL,
      requiresConfiguration: policy?.requiresConfiguration ?? false,
      requiresHeadlessAlwaysProceed: policy?.requiresHeadlessAlwaysProceed ?? false,
      registrationTrustProfile: policy?.registrationTrustProfile.rawValue ?? "managed",
      supportsModelSelection: policy?.supportsModelSelection ?? true,
      supportsEffortSelection: policy?.supportsEffortSelection ?? true,
      supportsSessionContinuation: policy?.supportsSessionContinuation ?? true,
      supportsSteer: policy?.supportsSteer ?? false,
      supportsWorkspaceWrite: policy?.supportsWorkspaceWrite ?? true,
      supportsSkillSelection: policy?.supportsSkillSelection ?? false,
      supportsSupervisor: policy?.supportsSupervisor ?? false,
      workspaceEnforcement: policy?.workspaceEnforcement ?? "legacy",
      approvalEnforcement: policy?.approvalEnforcement ?? "legacy",
      networkEnforcement: policy?.networkEnforcement ?? "legacy",
      qoderDistribution: qoderDistribution,
      qoderRegionSettings: qoderRegionSettings
    )
  }

  private static func qoderRegionSummary(
    _ value: ServiceQoderRuntimeSettings
  ) -> IPCAgentQoderRegionSettings {
    IPCAgentQoderRegionSettings(
      distribution: value.distribution.rawValue,
      activeInstallationID: value.activeInstallationID,
      nodeExecutablePath: value.nodeExecutablePath,
      sdkRoot: value.sdkRoot
    )
  }

  static func agentInstallationSummary(
    _ record: ServiceAgentInstallationRecord,
    distribution: String? = nil,
    isActive: Bool? = nil
  ) -> IPCAgentInstallationSummary {
    let formatter = ISO8601DateFormatter()
    return IPCAgentInstallationSummary(
      installationID: record.id.rawValue,
      providerID: record.providerID.rawValue,
      displayName: record.displayName,
      executablePath: record.executablePath,
      version: record.version,
      protocolRevision: record.protocolRevision,
      adapterRevision: record.adapterRevision,
      trustProfile: record.trustProfile.rawValue,
      securityProfileID: record.securityProfileID?.rawValue,
      isEnabled: record.isEnabled,
      availability: record.availability.rawValue,
      effectiveCapabilities: record.capabilities.effective
        .map(\.rawValue)
        .sorted(),
      lastProbeError: record.lastProbeError,
      lastProbedAt: record.lastProbedAt.map(formatter.string(from:)),
      updatedAt: formatter.string(from: record.updatedAt),
      distribution: distribution
        ?? QoderDistribution.identify(executablePath: record.executablePath)?.rawValue,
      isActive: isActive
    )
  }
}

extension BridgeServiceRequestController {
  func handleSubmitAgentTask(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(IPCAgentSubmitRequest.self, from: request)
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    let result = try await composition.application.serviceSubmitAgentTask(
      projectID: payload.projectID,
      providerID: payload.providerID,
      installationID: payload.installationID,
      model: payload.model,
      effort: payload.effort,
      permissionMode: payload.permissionMode,
      networkAccess: payload.networkAccess ?? false,
      prompt: payload.prompt,
      threadID: payload.threadID,
      skillName: payload.skillName,
      skillNames: payload.skillNames,
      modelOverride: payload.modelOverride,
      permissionModeOverride: payload.permissionModeOverride,
      acceptanceCriteria: payload.acceptanceCriteria ?? [],
      clientRequestID: payload.clientRequestID,
      queueIfBusy: payload.queueIfBusy ?? false,
      attachmentPaths: payload.attachmentPaths,
      attachmentSourceTaskID: payload.attachmentSourceTaskID,
      deadline: deadline
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCAgentSubmitResponse(taskID: result.taskID, status: result.status)
    )
  }

  func handleListAgentModels(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(IPCAgentModelsRequest.self, from: request)
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    let items = try await composition.application.serviceListAgentModels(
      installationID: AgentInstallationID(rawValue: payload.installationID),
      projectID: payload.projectID,
      modelID: payload.modelID,
      useStoredDefault: payload.useStoredDefault != false,
      forceRefresh: payload.forceRefresh == true,
      deadline: deadline
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCAgentModelsResponse(
        models: items.map {
          IPCAgentModelSummary(
            modelID: $0.modelID,
            displayName: $0.displayName,
            supportedReasoningEfforts: $0.supportedReasoningEfforts,
            defaultReasoningEffort: $0.defaultReasoningEffort,
            reasoningCapabilitiesAvailable: $0.reasoningCapabilitiesAvailable,
            isDefaultModel: $0.isDefaultModel
          )
        }
      )
    )
  }
}

extension BridgeServiceRequestController {
  func handleGetAgentModelDefault(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.optionalPayload(
      IPCAgentModelDefaultRequest.self,
      from: request
    )
    let providerID = AgentProviderID(
      rawValue: payload?.providerID ?? AgentProviderID.openCode.rawValue)
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    let persisted = try await composition.application.serviceAgentModelDefault(
      providerID: providerID,
      deadline: deadline
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCAgentModelDefaultResponse(
        providerID: providerID.rawValue,
        model: persisted.model,
        permissionMode: persisted.permissionMode,
        effort: persisted.effort
      )
    )
  }

  func handleSetAgentModelDefault(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(IPCAgentModelDefaultRequest.self, from: request)
    let providerID = AgentProviderID(
      rawValue: payload.providerID ?? AgentProviderID.openCode.rawValue)
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    let persisted = try await composition.application.serviceSetAgentModelDefault(
      providerID: providerID,
      model: payload.model,
      permissionMode: payload.permissionMode,
      effort: payload.effort.flatMap { $0.isEmpty ? nil : $0 },
      updateEffort: payload.effort != nil,
      deadline: deadline
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCAgentModelDefaultResponse(
        providerID: providerID.rawValue,
        model: persisted.model,
        permissionMode: persisted.permissionMode,
        effort: persisted.effort
      )
    )
  }

}
