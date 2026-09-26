import Foundation

public struct IPCAgentProviderSummary: Codable, Equatable, Sendable {
  public let providerID: String
  public let displayName: String
  public let adapterRevision: Int
  public let discoveryState: String?
  public let discoveryMessage: String?
  public let discoveredExecutablePath: String?
  public let discoveredConfigurationPath: String?
  public let configuredBaseURL: String?
  public let requiresConfiguration: Bool
  public let requiresHeadlessAlwaysProceed: Bool
  public let registrationTrustProfile: String
  public let supportsModelSelection: Bool
  public let supportsEffortSelection: Bool
  public let supportsSessionContinuation: Bool
  public let supportsSteer: Bool
  public let supportsWorkspaceWrite: Bool
  public let supportsSkillSelection: Bool
  public let supportsSupervisor: Bool
  public let workspaceEnforcement: String
  public let approvalEnforcement: String
  public let networkEnforcement: String
  public let qoderDistribution: String?
  public let qoderRegionSettings: [IPCAgentQoderRegionSettings]?

  public init(
    providerID: String,
    displayName: String,
    adapterRevision: Int,
    discoveryState: String? = nil,
    discoveryMessage: String? = nil,
    discoveredExecutablePath: String? = nil,
    discoveredConfigurationPath: String? = nil,
    configuredBaseURL: String? = nil,
    requiresConfiguration: Bool = false,
    requiresHeadlessAlwaysProceed: Bool = false,
    registrationTrustProfile: String = "managed",
    supportsModelSelection: Bool = true,
    supportsEffortSelection: Bool = true,
    supportsSessionContinuation: Bool = true,
    supportsSteer: Bool = false,
    supportsWorkspaceWrite: Bool = true,
    supportsSkillSelection: Bool = false,
    supportsSupervisor: Bool = false,
    workspaceEnforcement: String = "legacy",
    approvalEnforcement: String = "legacy",
    networkEnforcement: String = "legacy",
    qoderDistribution: String? = nil,
    qoderRegionSettings: [IPCAgentQoderRegionSettings]? = nil
  ) {
    self.providerID = providerID
    self.displayName = displayName
    self.adapterRevision = adapterRevision
    self.discoveryState = discoveryState
    self.discoveryMessage = discoveryMessage
    self.discoveredExecutablePath = discoveredExecutablePath
    self.discoveredConfigurationPath = discoveredConfigurationPath
    self.configuredBaseURL = configuredBaseURL
    self.requiresConfiguration = requiresConfiguration
    self.requiresHeadlessAlwaysProceed = requiresHeadlessAlwaysProceed
    self.registrationTrustProfile = registrationTrustProfile
    self.supportsModelSelection = supportsModelSelection
    self.supportsEffortSelection = supportsEffortSelection
    self.supportsSessionContinuation = supportsSessionContinuation
    self.supportsSteer = supportsSteer
    self.supportsWorkspaceWrite = supportsWorkspaceWrite
    self.supportsSkillSelection = supportsSkillSelection
    self.supportsSupervisor = supportsSupervisor
    self.workspaceEnforcement = workspaceEnforcement
    self.approvalEnforcement = approvalEnforcement
    self.networkEnforcement = networkEnforcement
    self.qoderDistribution = qoderDistribution
    self.qoderRegionSettings = qoderRegionSettings
  }

  private enum CodingKeys: String, CodingKey {
    case providerID = "provider_id"
    case displayName = "display_name"
    case adapterRevision = "adapter_revision"
    case discoveryState = "discovery_state"
    case discoveryMessage = "discovery_message"
    case discoveredExecutablePath = "discovered_executable_path"
    case discoveredConfigurationPath = "discovered_configuration_path"
    case configuredBaseURL = "configured_base_url"
    case requiresConfiguration = "requires_configuration"
    case requiresHeadlessAlwaysProceed = "requires_headless_always_proceed"
    case registrationTrustProfile = "registration_trust_profile"
    case supportsModelSelection = "supports_model_selection"
    case supportsEffortSelection = "supports_effort_selection"
    case supportsSessionContinuation = "supports_session_continuation"
    case supportsSteer = "supports_steer"
    case supportsWorkspaceWrite = "supports_workspace_write"
    case supportsSkillSelection = "supports_skill_selection"
    case supportsSupervisor = "supports_supervisor"
    case workspaceEnforcement = "workspace_enforcement"
    case approvalEnforcement = "approval_enforcement"
    case networkEnforcement = "network_enforcement"
    case qoderDistribution = "qoder_distribution"
    case qoderRegionSettings = "qoder_region_settings"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      providerID: try container.decode(String.self, forKey: .providerID),
      displayName: try container.decode(String.self, forKey: .displayName),
      adapterRevision: try container.decode(Int.self, forKey: .adapterRevision),
      discoveryState: try container.decodeIfPresent(String.self, forKey: .discoveryState),
      discoveryMessage: try container.decodeIfPresent(String.self, forKey: .discoveryMessage),
      discoveredExecutablePath: try container.decodeIfPresent(
        String.self,
        forKey: .discoveredExecutablePath
      ),
      discoveredConfigurationPath: try container.decodeIfPresent(
        String.self,
        forKey: .discoveredConfigurationPath
      ),
      configuredBaseURL: try container.decodeIfPresent(
        String.self,
        forKey: .configuredBaseURL
      ),
      requiresConfiguration: try container.decodeIfPresent(
        Bool.self,
        forKey: .requiresConfiguration
      ) ?? false,
      requiresHeadlessAlwaysProceed: try container.decodeIfPresent(
        Bool.self,
        forKey: .requiresHeadlessAlwaysProceed
      ) ?? false,
      registrationTrustProfile: try container.decodeIfPresent(
        String.self,
        forKey: .registrationTrustProfile
      ) ?? "managed",
      supportsModelSelection: try container.decodeIfPresent(
        Bool.self,
        forKey: .supportsModelSelection
      ) ?? true,
      supportsEffortSelection: try container.decodeIfPresent(
        Bool.self,
        forKey: .supportsEffortSelection
      ) ?? true,
      supportsSessionContinuation: try container.decodeIfPresent(
        Bool.self,
        forKey: .supportsSessionContinuation
      ) ?? true,
      supportsSteer: try container.decodeIfPresent(
        Bool.self,
        forKey: .supportsSteer
      ) ?? false,
      supportsWorkspaceWrite: try container.decodeIfPresent(
        Bool.self,
        forKey: .supportsWorkspaceWrite
      ) ?? true,
      supportsSkillSelection: try container.decodeIfPresent(
        Bool.self,
        forKey: .supportsSkillSelection
      ) ?? false,
      supportsSupervisor: try container.decodeIfPresent(
        Bool.self,
        forKey: .supportsSupervisor
      ) ?? false,
      workspaceEnforcement: try container.decodeIfPresent(
        String.self,
        forKey: .workspaceEnforcement
      ) ?? "legacy",
      approvalEnforcement: try container.decodeIfPresent(
        String.self,
        forKey: .approvalEnforcement
      ) ?? "legacy",
      networkEnforcement: try container.decodeIfPresent(
        String.self,
        forKey: .networkEnforcement
      ) ?? "legacy",
      qoderDistribution: try container.decodeIfPresent(String.self, forKey: .qoderDistribution),
      qoderRegionSettings: try container.decodeIfPresent(
        [IPCAgentQoderRegionSettings].self,
        forKey: .qoderRegionSettings
      )
    )
  }
}

public struct IPCAgentQoderRegionSettings: Codable, Equatable, Sendable {
  public let distribution: String
  public let activeInstallationID: String?
  public let nodeExecutablePath: String?
  public let sdkRoot: String?

  public init(
    distribution: String,
    activeInstallationID: String? = nil,
    nodeExecutablePath: String? = nil,
    sdkRoot: String? = nil
  ) {
    self.distribution = distribution
    self.activeInstallationID = activeInstallationID
    self.nodeExecutablePath = nodeExecutablePath
    self.sdkRoot = sdkRoot
  }

  private enum CodingKeys: String, CodingKey {
    case distribution
    case activeInstallationID = "active_installation_id"
    case nodeExecutablePath = "node_executable_path"
    case sdkRoot = "sdk_root"
  }
}

public struct IPCAgentInstallationSummary: Codable, Equatable, Sendable {
  public let installationID: String
  public let providerID: String
  public let displayName: String
  public let executablePath: String
  public let version: String?
  public let protocolRevision: String?
  public let adapterRevision: Int
  public let trustProfile: String
  public let securityProfileID: String?
  public let isEnabled: Bool
  public let availability: String
  public let effectiveCapabilities: [String]
  public let lastProbeError: String?
  public let lastProbedAt: String?
  public let updatedAt: String
  public let distribution: String?
  public let isActive: Bool?

  public init(
    installationID: String,
    providerID: String,
    displayName: String,
    executablePath: String,
    version: String? = nil,
    protocolRevision: String? = nil,
    adapterRevision: Int,
    trustProfile: String,
    securityProfileID: String? = nil,
    isEnabled: Bool,
    availability: String,
    effectiveCapabilities: [String],
    lastProbeError: String? = nil,
    lastProbedAt: String? = nil,
    updatedAt: String,
    distribution: String? = nil,
    isActive: Bool? = nil
  ) {
    self.installationID = installationID
    self.providerID = providerID
    self.displayName = displayName
    self.executablePath = executablePath
    self.version = version
    self.protocolRevision = protocolRevision
    self.adapterRevision = adapterRevision
    self.trustProfile = trustProfile
    self.securityProfileID = securityProfileID
    self.isEnabled = isEnabled
    self.availability = availability
    self.effectiveCapabilities = effectiveCapabilities
    self.lastProbeError = lastProbeError
    self.lastProbedAt = lastProbedAt
    self.updatedAt = updatedAt
    self.distribution = distribution
    self.isActive = isActive
  }

  private enum CodingKeys: String, CodingKey {
    case installationID = "installation_id"
    case providerID = "provider_id"
    case displayName = "display_name"
    case executablePath = "executable_path"
    case version
    case protocolRevision = "protocol_revision"
    case adapterRevision = "adapter_revision"
    case trustProfile = "trust_profile"
    case securityProfileID = "security_profile_id"
    case isEnabled = "is_enabled"
    case availability
    case effectiveCapabilities = "effective_capabilities"
    case lastProbeError = "last_probe_error"
    case lastProbedAt = "last_probed_at"
    case updatedAt = "updated_at"
    case distribution
    case isActive = "is_active"
  }
}

public struct IPCAgentCatalogResponse: Codable, Equatable, Sendable {
  public let providers: [IPCAgentProviderSummary]
  public let installations: [IPCAgentInstallationSummary]

  public init(
    providers: [IPCAgentProviderSummary],
    installations: [IPCAgentInstallationSummary]
  ) {
    self.providers = providers
    self.installations = installations
  }
}

public struct IPCAgentCatalogRequest: Codable, Equatable, Sendable {
  public let forceRefresh: Bool

  public init(forceRefresh: Bool = false) {
    self.forceRefresh = forceRefresh
  }

  private enum CodingKeys: String, CodingKey {
    case forceRefresh = "force_refresh"
  }
}

public struct IPCAgentRegistrationRequest: Codable, Equatable, Sendable {
  public let providerID: String
  public let displayName: String
  public let executablePath: String
  public let configurationPath: String?
  public let qoderDistribution: String?

  public init(
    providerID: String,
    displayName: String,
    executablePath: String,
    configurationPath: String? = nil,
    qoderDistribution: String? = nil
  ) {
    self.providerID = providerID
    self.displayName = displayName
    self.executablePath = executablePath
    self.configurationPath = configurationPath
    self.qoderDistribution = qoderDistribution
  }

  private enum CodingKeys: String, CodingKey {
    case providerID = "provider_id"
    case displayName = "display_name"
    case executablePath = "executable_path"
    case configurationPath = "configuration_path"
    case qoderDistribution = "qoder_distribution"
  }
}

public struct IPCAgentConnectRequest: Codable, Equatable, Sendable {
  public let providerID: String
  public let baseURL: String?
  public let apiKey: String?
  public let alwaysProceedConfirmed: Bool
  public let qoderDistribution: String?
  public let installationID: String?

  public init(
    providerID: String,
    baseURL: String? = nil,
    apiKey: String? = nil,
    alwaysProceedConfirmed: Bool = false,
    qoderDistribution: String? = nil,
    installationID: String? = nil
  ) {
    self.providerID = providerID
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.alwaysProceedConfirmed = alwaysProceedConfirmed
    self.qoderDistribution = qoderDistribution
    self.installationID = installationID
  }

  private enum CodingKeys: String, CodingKey {
    case providerID = "provider_id"
    case baseURL = "base_url"
    case apiKey = "api_key"
    case alwaysProceedConfirmed = "always_proceed_confirmed"
    case qoderDistribution = "qoder_distribution"
    case installationID = "installation_id"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      providerID: try container.decode(String.self, forKey: .providerID),
      baseURL: try container.decodeIfPresent(String.self, forKey: .baseURL),
      apiKey: try container.decodeIfPresent(String.self, forKey: .apiKey),
      alwaysProceedConfirmed: try container.decodeIfPresent(
        Bool.self,
        forKey: .alwaysProceedConfirmed
      ) ?? false,
      qoderDistribution: try container.decodeIfPresent(String.self, forKey: .qoderDistribution),
      installationID: try container.decodeIfPresent(String.self, forKey: .installationID)
    )
  }
}

public struct IPCAgentReprobeRequest: Codable, Equatable, Sendable {
  public let installationID: String
  public let acceptReplacement: Bool

  public init(installationID: String, acceptReplacement: Bool = false) {
    self.installationID = installationID
    self.acceptReplacement = acceptReplacement
  }

  private enum CodingKeys: String, CodingKey {
    case installationID = "installation_id"
    case acceptReplacement = "accept_replacement"
  }
}

public struct IPCAgentEnabledRequest: Codable, Equatable, Sendable {
  public let installationID: String
  public let enabled: Bool

  public init(installationID: String, enabled: Bool) {
    self.installationID = installationID
    self.enabled = enabled
  }

  private enum CodingKeys: String, CodingKey {
    case installationID = "installation_id"
    case enabled
  }
}

public struct IPCAgentInstallationIDRequest: Codable, Equatable, Sendable {
  public let installationID: String

  public init(installationID: String) {
    self.installationID = installationID
  }

  private enum CodingKeys: String, CodingKey {
    case installationID = "installation_id"
  }
}

public struct IPCAgentSubmitRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let providerID: String
  public let installationID: String?
  public let model: String?
  public let effort: String?
  public let permissionMode: String?
  public let prompt: String
  public let threadID: String?
  public let skillName: String?
  public let skillNames: [String]?
  public let networkAccess: Bool?
  public let modelOverride: Bool?
  public let permissionModeOverride: Bool?
  public let acceptanceCriteria: [String]?
  public let clientRequestID: String?
  public let queueIfBusy: Bool?
  public let attachmentPaths: [String]?
  public let attachmentSourceTaskID: String?

  public init(
    projectID: String,
    providerID: String,
    installationID: String? = nil,
    model: String? = nil,
    effort: String? = nil,
    permissionMode: String? = nil,
    prompt: String,
    threadID: String? = nil,
    skillName: String? = nil,
    skillNames: [String]? = nil,
    networkAccess: Bool? = nil,
    modelOverride: Bool? = nil,
    permissionModeOverride: Bool? = nil,
    acceptanceCriteria: [String]? = nil,
    clientRequestID: String? = nil,
    queueIfBusy: Bool? = nil,
    attachmentPaths: [String]? = nil,
    attachmentSourceTaskID: String? = nil
  ) {
    self.projectID = projectID
    self.providerID = providerID
    self.installationID = installationID
    self.model = model
    self.effort = effort
    self.permissionMode = permissionMode
    self.prompt = prompt
    self.threadID = threadID
    self.skillName = skillName
    self.skillNames = skillNames
    self.networkAccess = networkAccess
    self.modelOverride = modelOverride
    self.permissionModeOverride = permissionModeOverride
    self.acceptanceCriteria = acceptanceCriteria
    self.clientRequestID = clientRequestID
    self.queueIfBusy = queueIfBusy
    self.attachmentPaths = attachmentPaths
    self.attachmentSourceTaskID = attachmentSourceTaskID
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case providerID = "provider_id"
    case installationID = "installation_id"
    case model
    case effort
    case permissionMode = "permission_mode"
    case prompt
    case threadID = "thread_id"
    case skillName = "skill_name"
    case skillNames = "skill_names"
    case networkAccess = "network_access"
    case modelOverride = "model_override"
    case permissionModeOverride = "permission_mode_override"
    case acceptanceCriteria = "acceptance_criteria"
    case clientRequestID = "client_request_id"
    case queueIfBusy = "queue_if_busy"
    case attachmentPaths = "attachment_paths"
    case attachmentSourceTaskID = "attachment_source_task_id"
  }
}

public struct IPCAgentSubmitResponse: Codable, Equatable, Sendable {
  public let taskID: String
  public let status: String

  public init(taskID: String, status: String) {
    self.taskID = taskID
    self.status = status
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case status
  }
}

public struct IPCAgentModelsRequest: Codable, Equatable, Sendable {
  public let installationID: String
  public let projectID: String?
  public let modelID: String?
  public let useStoredDefault: Bool?
  public let forceRefresh: Bool?

  public init(
    installationID: String,
    projectID: String? = nil,
    modelID: String? = nil,
    useStoredDefault: Bool? = nil,
    forceRefresh: Bool? = nil
  ) {
    self.installationID = installationID
    self.projectID = projectID
    self.modelID = modelID
    self.useStoredDefault = useStoredDefault
    self.forceRefresh = forceRefresh
  }

  private enum CodingKeys: String, CodingKey {
    case installationID = "installation_id"
    case projectID = "project_id"
    case modelID = "model_id"
    case useStoredDefault = "use_stored_default"
    case forceRefresh = "force_refresh"
  }
}

public struct IPCAgentModelSummary: Codable, Equatable, Sendable {
  public let modelID: String
  public let displayName: String
  public let supportedReasoningEfforts: [String]
  public let defaultReasoningEffort: String?
  public let reasoningCapabilitiesAvailable: Bool?
  public let isDefaultModel: Bool?

  public init(
    modelID: String,
    displayName: String,
    supportedReasoningEfforts: [String] = [],
    defaultReasoningEffort: String? = nil,
    reasoningCapabilitiesAvailable: Bool? = nil,
    isDefaultModel: Bool? = nil
  ) {
    self.modelID = modelID
    self.displayName = displayName
    self.supportedReasoningEfforts = supportedReasoningEfforts
    self.defaultReasoningEffort = defaultReasoningEffort
    self.reasoningCapabilitiesAvailable = reasoningCapabilitiesAvailable
    self.isDefaultModel = isDefaultModel
  }

  private enum CodingKeys: String, CodingKey {
    case modelID = "model_id"
    case displayName = "display_name"
    case supportedReasoningEfforts = "supported_reasoning_efforts"
    case defaultReasoningEffort = "default_reasoning_effort"
    case reasoningCapabilitiesAvailable = "reasoning_capabilities_available"
    case isDefaultModel = "is_default_model"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      modelID: try container.decode(String.self, forKey: .modelID),
      displayName: try container.decode(String.self, forKey: .displayName),
      supportedReasoningEfforts: try container.decodeIfPresent(
        [String].self,
        forKey: .supportedReasoningEfforts
      ) ?? [],
      defaultReasoningEffort: try container.decodeIfPresent(
        String.self,
        forKey: .defaultReasoningEffort
      ),
      reasoningCapabilitiesAvailable: try container.decodeIfPresent(
        Bool.self,
        forKey: .reasoningCapabilitiesAvailable
      ),
      isDefaultModel: try container.decodeIfPresent(Bool.self, forKey: .isDefaultModel)
    )
  }
}

public struct IPCAgentModelsResponse: Codable, Equatable, Sendable {
  public let models: [IPCAgentModelSummary]

  public init(models: [IPCAgentModelSummary]) {
    self.models = models
  }
}

public struct IPCAgentModelDefaultResponse: Codable, Equatable, Sendable {
  public let providerID: String
  public let model: String?
  public let permissionMode: String
  public let effort: String?

  public init(
    providerID: String = "opencode",
    model: String?,
    permissionMode: String = "build",
    effort: String? = nil
  ) {
    self.providerID = providerID
    self.model = model
    self.permissionMode = permissionMode
    self.effort = effort
  }

  private enum CodingKeys: String, CodingKey {
    case providerID = "provider_id"
    case model
    case permissionMode = "permission_mode"
    case effort
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      providerID: try container.decodeIfPresent(String.self, forKey: .providerID) ?? "opencode",
      model: try container.decodeIfPresent(String.self, forKey: .model),
      permissionMode: try container.decodeIfPresent(String.self, forKey: .permissionMode)
        ?? "build",
      effort: try container.decodeIfPresent(String.self, forKey: .effort)
    )
  }
}

public struct IPCAgentModelDefaultRequest: Codable, Equatable, Sendable {
  public let providerID: String?
  public let model: String?
  public let permissionMode: String?
  public let effort: String?

  public init(
    providerID: String? = nil,
    model: String?,
    permissionMode: String? = nil,
    effort: String? = nil
  ) {
    self.providerID = providerID
    self.model = model
    self.permissionMode = permissionMode
    self.effort = effort
  }

  private enum CodingKeys: String, CodingKey {
    case providerID = "provider_id"
    case model
    case permissionMode = "permission_mode"
    case effort
  }
}

public struct IPCAgentQoderRuntimeSettingsRequest: Codable, Equatable, Sendable {
  public let distribution: String
  public let activeInstallationID: String?
  public let nodeExecutablePath: String?
  public let sdkRoot: String?

  public init(
    distribution: String,
    activeInstallationID: String?,
    nodeExecutablePath: String?,
    sdkRoot: String?
  ) {
    self.distribution = distribution
    self.activeInstallationID = activeInstallationID
    self.nodeExecutablePath = nodeExecutablePath
    self.sdkRoot = sdkRoot
  }

  private enum CodingKeys: String, CodingKey {
    case distribution
    case activeInstallationID = "active_installation_id"
    case nodeExecutablePath = "node_executable_path"
    case sdkRoot = "sdk_root"
  }
}
