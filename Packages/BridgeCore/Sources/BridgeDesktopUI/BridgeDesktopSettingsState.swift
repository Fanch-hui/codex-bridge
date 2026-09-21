import Foundation

public struct BridgeDesktopModelOption: Codable, Equatable, Sendable {
  public let modelID: String
  public let displayName: String
  public let reasoningEfforts: [BridgeDesktopChoice]
  public let defaultReasoningEffort: String?
  public let supportsFastMode: Bool?
  public let reasoningCapabilitiesAvailable: Bool?
  public let isDefaultModel: Bool?

  public init(
    modelID: String,
    displayName: String,
    reasoningEfforts: [BridgeDesktopChoice] = [],
    defaultReasoningEffort: String? = nil,
    supportsFastMode: Bool? = nil,
    reasoningCapabilitiesAvailable: Bool? = nil,
    isDefaultModel: Bool? = nil
  ) {
    self.modelID = modelID
    self.displayName = displayName
    self.reasoningEfforts = reasoningEfforts
    self.defaultReasoningEffort = defaultReasoningEffort
    self.supportsFastMode = supportsFastMode
    self.reasoningCapabilitiesAvailable = reasoningCapabilitiesAvailable
    self.isDefaultModel = isDefaultModel
  }
}

public struct BridgeDesktopAgentDefaultState: Codable, Equatable, Sendable {
  public let providerID: String
  public let providerName: String
  public let installationID: String?
  public let installationName: String?
  public let model: String?
  public let modelOptions: [BridgeDesktopModelOption]
  public let effort: String?
  public let effortOptions: [BridgeDesktopChoice]
  public let permissionMode: String
  public let permissionOptions: [BridgeDesktopChoice]
  public let supportsWorkspaceWrite: Bool?
  public let canSelectModel: Bool?
  public let canSelectEffort: Bool?
  public let canSave: Bool
  public let canRefreshModels: Bool
  public let isRefreshingModels: Bool
  public let errorMessage: String?

  public init(
    providerID: String,
    providerName: String,
    installationID: String? = nil,
    installationName: String? = nil,
    model: String? = nil,
    modelOptions: [BridgeDesktopModelOption] = [],
    effort: String? = nil,
    effortOptions: [BridgeDesktopChoice] = [],
    permissionMode: String = "",
    permissionOptions: [BridgeDesktopChoice] = [],
    supportsWorkspaceWrite: Bool? = true,
    canSave: Bool = true,
    canRefreshModels: Bool = false,
    isRefreshingModels: Bool = false,
    errorMessage: String? = nil,
    canSelectModel: Bool? = nil,
    canSelectEffort: Bool? = nil
  ) {
    self.providerID = providerID
    self.providerName = providerName
    self.installationID = installationID
    self.installationName = installationName
    self.model = model
    self.modelOptions = modelOptions
    self.effort = effort
    self.effortOptions = effortOptions
    self.permissionMode = permissionMode
    self.permissionOptions = permissionOptions
    self.supportsWorkspaceWrite = supportsWorkspaceWrite
    self.canSelectModel = canSelectModel
    self.canSelectEffort = canSelectEffort
    self.canSave = canSave
    self.canRefreshModels = canRefreshModels
    self.isRefreshingModels = isRefreshingModels
    self.errorMessage = errorMessage
  }
}

public struct BridgeDesktopNativePermissionMode: Codable, Equatable, Sendable {
  public let modeID: String
  public let displayName: String
  public let requiresConfirmation: Bool

  public init(
    modeID: String,
    displayName: String,
    requiresConfirmation: Bool = false
  ) {
    self.modeID = modeID
    self.displayName = displayName
    self.requiresConfirmation = requiresConfirmation
  }
}

public struct BridgeDesktopNativePermissionRule: Codable, Equatable, Sendable {
  public let ruleID: String
  public let effect: String
  public let action: String
  public let target: String
  public let isEditable: Bool
  public let isRedacted: Bool
  public let requiresConfirmation: Bool

  public init(
    ruleID: String,
    effect: String,
    action: String,
    target: String,
    isEditable: Bool,
    isRedacted: Bool,
    requiresConfirmation: Bool = false
  ) {
    self.ruleID = ruleID
    self.effect = effect
    self.action = action
    self.target = target
    self.isEditable = isEditable
    self.isRedacted = isRedacted
    self.requiresConfirmation = requiresConfirmation
  }
}

public struct BridgeDesktopNativePermissionState: Codable, Equatable, Sendable {
  public let providerID: String
  public let providerName: String
  public let installationID: String
  public let installationName: String
  public let installations: [BridgeDesktopChoice]
  public let toolPermission: String?
  public let availableModes: [BridgeDesktopNativePermissionMode]
  public let availableActions: [String]
  public let rules: [BridgeDesktopNativePermissionRule]
  public let warnings: [String]
  public let isLoading: Bool
  public let isSaving: Bool
  public let canEdit: Bool
  public let errorMessage: String?

  public init(
    providerID: String,
    providerName: String,
    installationID: String,
    installationName: String,
    installations: [BridgeDesktopChoice] = [],
    toolPermission: String? = nil,
    availableModes: [BridgeDesktopNativePermissionMode] = [],
    availableActions: [String] = [],
    rules: [BridgeDesktopNativePermissionRule] = [],
    warnings: [String] = [],
    isLoading: Bool = false,
    isSaving: Bool = false,
    canEdit: Bool = false,
    errorMessage: String? = nil
  ) {
    self.providerID = providerID
    self.providerName = providerName
    self.installationID = installationID
    self.installationName = installationName
    self.installations = installations
    self.toolPermission = toolPermission
    self.availableModes = availableModes
    self.availableActions = availableActions
    self.rules = rules
    self.warnings = warnings
    self.isLoading = isLoading
    self.isSaving = isSaving
    self.canEdit = canEdit
    self.errorMessage = errorMessage
  }
}

public struct BridgeDesktopSettingsState: Codable, Equatable, Sendable {
  public let header: BridgeDesktopPageHeader
  public let models: [BridgeDesktopModelOption]
  public let executionModel: String
  public let executionEffort: String
  public let effortOptions: [BridgeDesktopChoice]
  public let accessMode: String
  public let accessOptions: [BridgeDesktopChoice]
  public let fastModeEnabled: Bool
  public let directApprovalMode: String
  public let directApprovalOptions: [BridgeDesktopChoice]
  public let taskStartApprovalMode: String
  public let taskStartApprovalOptions: [BridgeDesktopChoice]
  public let customInstructions: String
  public let agentDefaults: [BridgeDesktopAgentDefaultState]
  public let nativePermissionPolicy: BridgeDesktopNativePermissionState?
  public let keepServiceRunningAfterExit: Bool
  public let serviceRegistered: Bool
  public let canSavePreferences: Bool
  public let canSaveInstructions: Bool
  public let canSaveApprovalModes: Bool
  public let canChangeService: Bool
  public let servicePlatform: String
  public let serviceDescription: String
  public let serviceStatus: String?
  public let serviceStatusTitle: String?
  public let serviceStatusMessage: String?
  public let serviceStatusTone: BridgeDesktopStatusTone?
  public let serviceActions: [BridgeDesktopActionLink]?
  public let direct: BridgeDesktopDirectState?
  public let statusMessage: String?
  public let modelCount: Int?
  public let canRefreshModels: Bool?
  public let isRefreshingModels: Bool?
  public let modelError: String?

  public init(
    header: BridgeDesktopPageHeader,
    models: [BridgeDesktopModelOption] = [],
    executionModel: String = "",
    executionEffort: String = "",
    effortOptions: [BridgeDesktopChoice] = [],
    accessMode: String = "request-approval",
    accessOptions: [BridgeDesktopChoice] = [],
    fastModeEnabled: Bool = false,
    directApprovalMode: String = "require",
    directApprovalOptions: [BridgeDesktopChoice] = [],
    taskStartApprovalMode: String = "require",
    taskStartApprovalOptions: [BridgeDesktopChoice] = [],
    customInstructions: String = "",
    agentDefaults: [BridgeDesktopAgentDefaultState] = [],
    nativePermissionPolicy: BridgeDesktopNativePermissionState? = nil,
    keepServiceRunningAfterExit: Bool = true,
    serviceRegistered: Bool = false,
    canSavePreferences: Bool = true,
    canSaveInstructions: Bool = true,
    canSaveApprovalModes: Bool = true,
    canChangeService: Bool = false,
    servicePlatform: String = "macOS",
    serviceDescription: String = "后台 Service 在 App 退出后继续提供本机 MCP 服务。",
    serviceStatus: String? = nil,
    serviceStatusTitle: String? = nil,
    serviceStatusMessage: String? = nil,
    serviceStatusTone: BridgeDesktopStatusTone? = nil,
    serviceActions: [BridgeDesktopActionLink]? = nil,
    statusMessage: String? = nil,
    modelCount: Int? = nil,
    canRefreshModels: Bool? = nil,
    isRefreshingModels: Bool? = nil,
    modelError: String? = nil,
    direct: BridgeDesktopDirectState? = nil
  ) {
    self.header = header
    self.models = models
    self.executionModel = executionModel
    self.executionEffort = executionEffort
    self.effortOptions = effortOptions
    self.accessMode = accessMode
    self.accessOptions = accessOptions
    self.fastModeEnabled = fastModeEnabled
    self.directApprovalMode = directApprovalMode
    self.directApprovalOptions = directApprovalOptions
    self.taskStartApprovalMode = taskStartApprovalMode
    self.taskStartApprovalOptions = taskStartApprovalOptions
    self.customInstructions = customInstructions
    self.agentDefaults = agentDefaults
    self.nativePermissionPolicy = nativePermissionPolicy
    self.keepServiceRunningAfterExit = keepServiceRunningAfterExit
    self.serviceRegistered = serviceRegistered
    self.canSavePreferences = canSavePreferences
    self.canSaveInstructions = canSaveInstructions
    self.canSaveApprovalModes = canSaveApprovalModes
    self.canChangeService = canChangeService
    self.servicePlatform = servicePlatform
    self.serviceDescription = serviceDescription
    self.serviceStatus = serviceStatus
    self.serviceStatusTitle = serviceStatusTitle
    self.serviceStatusMessage = serviceStatusMessage
    self.serviceStatusTone = serviceStatusTone
    self.serviceActions = serviceActions
    self.direct = direct
    self.statusMessage = statusMessage
    self.modelCount = modelCount
    self.canRefreshModels = canRefreshModels
    self.isRefreshingModels = isRefreshingModels
    self.modelError = modelError
  }
}
