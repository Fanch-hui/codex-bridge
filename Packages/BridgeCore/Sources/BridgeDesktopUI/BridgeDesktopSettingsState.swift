import Foundation

public struct BridgeDesktopModelOption: Codable, Equatable, Sendable {
  public let modelID: String
  public let displayName: String
  public let reasoningEfforts: [BridgeDesktopChoice]

  public init(
    modelID: String,
    displayName: String,
    reasoningEfforts: [BridgeDesktopChoice] = []
  ) {
    self.modelID = modelID
    self.displayName = displayName
    self.reasoningEfforts = reasoningEfforts
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
    canSave: Bool = true,
    canRefreshModels: Bool = false,
    isRefreshingModels: Bool = false,
    errorMessage: String? = nil
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
    self.canSave = canSave
    self.canRefreshModels = canRefreshModels
    self.isRefreshingModels = isRefreshingModels
    self.errorMessage = errorMessage
  }
}

public struct BridgeDesktopSettingsState: Codable, Equatable, Sendable {
  public let header: BridgeDesktopPageHeader
  public let models: [BridgeDesktopModelOption]
  public let executionModel: String
  public let executionEffort: String
  public let supervisorModel: String
  public let supervisorEffort: String
  public let supervisorAvailable: Bool
  public let effortOptions: [BridgeDesktopChoice]
  public let supervisorEffortOptions: [BridgeDesktopChoice]
  public let accessMode: String
  public let accessOptions: [BridgeDesktopChoice]
  public let supervisorEnabled: Bool
  public let fastModeEnabled: Bool
  public let directApprovalMode: String
  public let directApprovalOptions: [BridgeDesktopChoice]
  public let taskStartApprovalMode: String
  public let taskStartApprovalOptions: [BridgeDesktopChoice]
  public let customInstructions: String
  public let agentDefaults: [BridgeDesktopAgentDefaultState]
  public let keepServiceRunningAfterExit: Bool
  public let serviceRegistered: Bool
  public let canSavePreferences: Bool
  public let canSaveInstructions: Bool
  public let canSaveApprovalModes: Bool
  public let canChangeService: Bool
  public let servicePlatform: String
  public let serviceDescription: String
  public let statusMessage: String?

  public init(
    header: BridgeDesktopPageHeader,
    models: [BridgeDesktopModelOption] = [],
    executionModel: String = "",
    executionEffort: String = "",
    supervisorModel: String = "",
    supervisorEffort: String = "",
    supervisorAvailable: Bool = true,
    effortOptions: [BridgeDesktopChoice] = [],
    supervisorEffortOptions: [BridgeDesktopChoice] = [],
    accessMode: String = "request-approval",
    accessOptions: [BridgeDesktopChoice] = [],
    supervisorEnabled: Bool = true,
    fastModeEnabled: Bool = false,
    directApprovalMode: String = "require",
    directApprovalOptions: [BridgeDesktopChoice] = [],
    taskStartApprovalMode: String = "require",
    taskStartApprovalOptions: [BridgeDesktopChoice] = [],
    customInstructions: String = "",
    agentDefaults: [BridgeDesktopAgentDefaultState] = [],
    keepServiceRunningAfterExit: Bool = true,
    serviceRegistered: Bool = false,
    canSavePreferences: Bool = true,
    canSaveInstructions: Bool = true,
    canSaveApprovalModes: Bool = true,
    canChangeService: Bool = false,
    servicePlatform: String = "macOS",
    serviceDescription: String = "后台 Service 在 App 退出后继续提供本机 MCP 服务。",
    statusMessage: String? = nil
  ) {
    self.header = header
    self.models = models
    self.executionModel = executionModel
    self.executionEffort = executionEffort
    self.supervisorModel = supervisorModel
    self.supervisorEffort = supervisorEffort
    self.supervisorAvailable = supervisorAvailable
    self.effortOptions = effortOptions
    self.supervisorEffortOptions = supervisorEffortOptions
    self.accessMode = accessMode
    self.accessOptions = accessOptions
    self.supervisorEnabled = supervisorEnabled
    self.fastModeEnabled = fastModeEnabled
    self.directApprovalMode = directApprovalMode
    self.directApprovalOptions = directApprovalOptions
    self.taskStartApprovalMode = taskStartApprovalMode
    self.taskStartApprovalOptions = taskStartApprovalOptions
    self.customInstructions = customInstructions
    self.agentDefaults = agentDefaults
    self.keepServiceRunningAfterExit = keepServiceRunningAfterExit
    self.serviceRegistered = serviceRegistered
    self.canSavePreferences = canSavePreferences
    self.canSaveInstructions = canSaveInstructions
    self.canSaveApprovalModes = canSaveApprovalModes
    self.canChangeService = canChangeService
    self.servicePlatform = servicePlatform
    self.serviceDescription = serviceDescription
    self.statusMessage = statusMessage
  }
}
