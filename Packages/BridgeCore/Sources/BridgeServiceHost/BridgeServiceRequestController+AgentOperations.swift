import BridgeAgentCore
import BridgeDeepSeekHarnessACP
import BridgeIPC
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
    let configuredDeepSeekBaseURL = try? await composition.application
      .serviceDeepSeekHarnessBaseURL(deadline: deadline)
    let discovery = await composition.agentDiscoveryCatalog.summaries(
      providerIDs: providers.map(\.providerID),
      existingInstallations: installations,
      forceRefresh: catalogRequest?.forceRefresh ?? false
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCAgentCatalogResponse(
        providers: providers.map { provider in
          Self.agentProviderSummary(
            provider,
            discovery: discovery[provider.providerID],
            configuredBaseURL: provider.providerID == .deepSeekHarness
              ? configuredDeepSeekBaseURL : nil
          )
        },
        installations: installations.map(Self.agentInstallationSummary)
      )
    )
  }

  func handleRegisterAgentInstallation(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCAgentRegistrationRequest.self,
      from: request
    )
    let providerID = AgentProviderID(rawValue: payload.providerID)
    let policy = ServiceAgentProviderPolicyRegistry.policy(for: providerID)
    let artifacts = try Self.registrationArtifacts(
      providerID: providerID,
      executablePath: payload.executablePath,
      configurationPath: payload.configurationPath
    )
    let record = try await composition.application.serviceRegisterManagedAgent(
      try ServiceAgentRegistrationRequest(
        providerID: providerID,
        displayName: payload.displayName,
        executablePath: payload.executablePath,
        trustProfile: policy?.registrationTrustProfile ?? .managed,
        securityProfileID: policy?.registrationSecurityProfileID,
        enableOnSuccess: false,
        configurationPath: payload.configurationPath,
        artifacts: artifacts
      ),
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: Self.agentInstallationSummary(record)
    )
  }

  func handleConnectAgentInstallation(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCAgentConnectRequest.self,
      from: request
    )
    let providerID = AgentProviderID(rawValue: payload.providerID)
    let existingInstallations = try await composition.agentRegistry.installations(
      providerID: providerID
    )
    let discovery = await composition.agentDiscoveryCatalog.summaries(
      providerIDs: [providerID], existingInstallations: existingInstallations
    )
    let discoveredPath = discovery[providerID]?.executablePath
    let environment = ToolDiscoveryEnvironment.current()
    let candidates = try ServiceAgentAutoDiscovery.registrationRequests(
      providerID: providerID,
      dataPaths: composition.paths,
      existingInstallations: existingInstallations,
      credentialsProvided: payload.baseURL != nil || payload.apiKey != nil,
      environment: environment,
      discoveredExecutablePath: discoveredPath
    )
    let record = try await composition.application.serviceConnectManagedAgent(
      providerID: providerID,
      baseURL: payload.baseURL,
      apiKey: payload.apiKey,
      candidates: candidates,
      alwaysProceedConfirmed: payload.alwaysProceedConfirmed,
      deadline: Self.deadline()
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: Self.agentInstallationSummary(record)
    )
  }

  private static func registrationArtifacts(
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
    configuredBaseURL: String?
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
      networkEnforcement: policy?.networkEnforcement ?? "legacy"
    )
  }

  private static func agentInstallationSummary(
    _ record: ServiceAgentInstallationRecord
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
      updatedAt: formatter.string(from: record.updatedAt)
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
      modelOverride: payload.modelOverride,
      permissionModeOverride: payload.permissionModeOverride,
      acceptanceCriteria: payload.acceptanceCriteria ?? [],
      clientRequestID: payload.clientRequestID,
      queueIfBusy: payload.queueIfBusy ?? false,
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
