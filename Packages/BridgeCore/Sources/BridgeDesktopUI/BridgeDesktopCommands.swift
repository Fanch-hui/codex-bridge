import Foundation

public enum BridgeDesktopCommand: String, Codable, Sendable {
  case ready
  case requestStateResync
  case refresh
  case checkAppUpdate
  case installAppUpdate
  case deferAppUpdate
  case refreshModels
  case scanAgents
  case selectPage
  case openWorkbench
  case openProjects
  case openConnections
  case openSettings
  case openLogs
  case openSystemSettings
  case openTask
  case browserBack
  case browserForward
  case browserReload
  case setBrowserEnabled
  case openExternalURL
  case copyTunnelID
  case openBrowserExternally
  case loadEarlierConversation
  case refreshConversation
  case setWorkbenchPermissionMode
  case selectTask
  case refreshTasks
  case interruptTask
  case stopTask
  case deleteTask
  case deleteSession
  case steerTask
  case resumeTask
  case handoffTask
  case restartTask
  case resolveApproval
  case resolveDirectApproval
  case selectProject
  case refreshProjects
  case registerProject
  case removeProject
  case saveProjectPolicy
  case setProjectCommandMode
  case saveProjectCommand
  case removeProjectCommand
  case saveProjectBlacklist
  case removeProjectBlacklist
  case openThread
  case selectLog
  case refreshLogs
  case setLogSearch
  case setLogProjectFilter
  case setLogKindFilter
  case copyLogs
  case setMCPClientEnabled
  case setMCPClientExposure
  case copyMCPClientConfiguration
  case copyLocalMCPEndpoint
  case rotateMCPClientCredential
  case rotateLocalMCPEndpoint
  case saveDeepSeekHarnessMCPServer
  case deleteDeepSeekHarnessMCPServer
  case setDeepSeekHarnessMCPServerEnabled
  case configureTunnel
  case connectTunnel
  case disconnectTunnel
  case clearTunnel
  case connectAgent
  case registerAgent
  case beginAgentRegistration
  case selectAgent
  case setAgentEnabled
  case reprobeAgent
  case removeAgent
  case refreshAgentModels
  case saveAgentDefault
  case refreshAgentNativePermission
  case setAgentNativePermissionMode
  case addAgentNativePermissionRule
  case replaceAgentNativePermissionRule
  case removeAgentNativePermissionRule
  case prepareAgentPermissionRemediation
  case applyAgentPermissionRemediation
  case setExecutionModel
  case setExecutionEffort
  case setAccessMode
  case setFastMode
  case setDirectApprovalMode
  case setTaskStartApprovalMode
  case saveSettings
  case saveDirectConfiguration
  case saveCustomInstructions
  case setCodexExecutable
  case registerService
  case unregisterService
  case setKeepServiceRunning
  case updateBrowserViewport
  case dismissFeedback
}

public struct BridgeDesktopCommandPayload: Codable, Equatable, Sendable {
  public let navigation: BridgeDesktopNavigation?
  public let taskID: String?
  public let sessionID: String?
  public let approvalID: String?
  public let projectID: String?
  public let tunnelID: String?
  public let threadID: String?
  public let providerID: String?
  public let installationID: String?
  public let clientID: String?
  public let mcpServerID: String?
  public let logID: String?
  public let commandID: String?
  public let ruleID: String?
  public let feedbackID: String?
  public let decision: String?
  public let input: String?
  public let mode: String?
  public let value: String?
  public let kind: String?
  public let searchText: String?
  public let name: String?
  public let path: String?
  public let executable: String?
  public let arguments: [String]?
  public let workingDirectory: String?
  public let requiresNetwork: Bool?
  public let risk: String?
  public let pattern: String?
  public let displayName: String?
  public let configurationPath: String?
  public let baseURL: String?
  public let apiKey: String?
  public let mcpTransport: String?
  public let mcpCommand: String?
  public let mcpURL: String?
  public let mcpEnvironmentSecrets: [BridgeDesktopSecretInput]?
  public let mcpHeaderSecrets: [BridgeDesktopSecretInput]?
  public let exposureMode: String?
  public let modelID: String?
  public let effort: String?
  public let permissionMode: String?
  public let messageKey: String?
  public let effect: String?
  public let action: String?
  public let target: String?
  public let toolPermission: String?
  public let runtimeKey: String?
  public let executionModel: String?
  public let executionEffort: String?
  public let accessMode: String?
  public let readPermission: String?
  public let writePermission: String?
  public let networkPermission: String?
  public let enabled: Bool?
  public let acceptReplacement: Bool?
  public let fastModeEnabled: Bool?
  public let keepServiceRunningAfterExit: Bool?
  public let oneTimeToolAutoApproval: Bool?
  public let queueIfBusy: Bool?
  public let confirmed: Bool?
  public let viewport: BridgeDesktopBrowserViewport?

  public init(
    navigation: BridgeDesktopNavigation? = nil,
    taskID: String? = nil,
    sessionID: String? = nil,
    approvalID: String? = nil,
    projectID: String? = nil,
    tunnelID: String? = nil,
    threadID: String? = nil,
    providerID: String? = nil,
    installationID: String? = nil,
    clientID: String? = nil,
    mcpServerID: String? = nil,
    logID: String? = nil,
    commandID: String? = nil,
    ruleID: String? = nil,
    feedbackID: String? = nil,
    decision: String? = nil,
    input: String? = nil,
    mode: String? = nil,
    value: String? = nil,
    kind: String? = nil,
    searchText: String? = nil,
    name: String? = nil,
    path: String? = nil,
    executable: String? = nil,
    arguments: [String]? = nil,
    workingDirectory: String? = nil,
    requiresNetwork: Bool? = nil,
    risk: String? = nil,
    pattern: String? = nil,
    displayName: String? = nil,
    configurationPath: String? = nil,
    baseURL: String? = nil,
    apiKey: String? = nil,
    mcpTransport: String? = nil,
    mcpCommand: String? = nil,
    mcpURL: String? = nil,
    mcpEnvironmentSecrets: [BridgeDesktopSecretInput]? = nil,
    mcpHeaderSecrets: [BridgeDesktopSecretInput]? = nil,
    exposureMode: String? = nil,
    modelID: String? = nil,
    effort: String? = nil,
    permissionMode: String? = nil,
    messageKey: String? = nil,
    effect: String? = nil,
    action: String? = nil,
    target: String? = nil,
    toolPermission: String? = nil,
    runtimeKey: String? = nil,
    executionModel: String? = nil,
    executionEffort: String? = nil,
    accessMode: String? = nil,
    readPermission: String? = nil,
    writePermission: String? = nil,
    networkPermission: String? = nil,
    enabled: Bool? = nil,
    acceptReplacement: Bool? = nil,
    fastModeEnabled: Bool? = nil,
    keepServiceRunningAfterExit: Bool? = nil,
    oneTimeToolAutoApproval: Bool? = nil,
    queueIfBusy: Bool? = nil,
    confirmed: Bool? = nil,
    viewport: BridgeDesktopBrowserViewport? = nil
  ) {
    self.navigation = navigation
    self.taskID = taskID
    self.sessionID = sessionID
    self.approvalID = approvalID
    self.projectID = projectID
    self.tunnelID = tunnelID
    self.threadID = threadID
    self.providerID = providerID
    self.installationID = installationID
    self.clientID = clientID
    self.mcpServerID = mcpServerID
    self.logID = logID
    self.commandID = commandID
    self.ruleID = ruleID
    self.feedbackID = feedbackID
    self.decision = decision
    self.input = input
    self.mode = mode
    self.value = value
    self.kind = kind
    self.searchText = searchText
    self.name = name
    self.path = path
    self.executable = executable
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.requiresNetwork = requiresNetwork
    self.risk = risk
    self.pattern = pattern
    self.displayName = displayName
    self.configurationPath = configurationPath
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.mcpTransport = mcpTransport
    self.mcpCommand = mcpCommand
    self.mcpURL = mcpURL
    self.mcpEnvironmentSecrets = mcpEnvironmentSecrets
    self.mcpHeaderSecrets = mcpHeaderSecrets
    self.exposureMode = exposureMode
    self.modelID = modelID
    self.effort = effort
    self.permissionMode = permissionMode
    self.messageKey = messageKey
    self.effect = effect
    self.action = action
    self.target = target
    self.toolPermission = toolPermission
    self.runtimeKey = runtimeKey
    self.executionModel = executionModel
    self.executionEffort = executionEffort
    self.accessMode = accessMode
    self.readPermission = readPermission
    self.writePermission = writePermission
    self.networkPermission = networkPermission
    self.enabled = enabled
    self.acceptReplacement = acceptReplacement
    self.fastModeEnabled = fastModeEnabled
    self.keepServiceRunningAfterExit = keepServiceRunningAfterExit
    self.oneTimeToolAutoApproval = oneTimeToolAutoApproval
    self.queueIfBusy = queueIfBusy
    self.confirmed = confirmed
    self.viewport = viewport
  }
}

public struct BridgeDesktopCommandEnvelope: Codable, Equatable, Sendable {
  public static let currentVersion = 1

  public let version: Int
  public let requestID: String
  public let command: BridgeDesktopCommand
  public let payload: BridgeDesktopCommandPayload

  public init(
    requestID: String,
    command: BridgeDesktopCommand,
    payload: BridgeDesktopCommandPayload = .init()
  ) {
    self.version = Self.currentVersion
    self.requestID = requestID
    self.command = command
    self.payload = payload
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case requestID
    case command
    case payload
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = try values.decode(Int.self, forKey: .version)
    requestID = try values.decode(String.self, forKey: .requestID)
    command = try values.decode(BridgeDesktopCommand.self, forKey: .command)
    payload =
      try values.decodeIfPresent(BridgeDesktopCommandPayload.self, forKey: .payload) ?? .init()
  }
}
