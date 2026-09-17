import Foundation

public struct BridgeDesktopTaskDetail: Codable, Equatable, Sendable {
  public let taskID: String
  public let sessionID: String
  public let title: String
  public let projectName: String
  public let isTerminal: Bool?
  public let status: String
  public let provider: String
  public let providerID: String
  public let model: String?
  public let permissionMode: String?
  public let currentStep: String?
  public let resultSummary: String?
  public let failureCode: String?
  public let changedFiles: [String]
  public let activity: [BridgeDesktopActivityRow]
  public let conversation: [BridgeDesktopConversationEntry]
  public let conversationState: BridgeDesktopConversationState?
  public let canInterrupt: Bool?
  public let canStop: Bool?
  public let canSteer: Bool?
  public let permissionRemediation: BridgeDesktopPermissionRemediationState?
  public let turnCount: Int
  public let canResume: Bool
  public let canRestart: Bool
  public let updatedAt: String

  public init(
    taskID: String,
    sessionID: String? = nil,
    title: String,
    projectName: String,
    status: String,
    isTerminal: Bool? = nil,
    provider: String,
    providerID: String = "codex",
    model: String? = nil,
    permissionMode: String? = nil,
    currentStep: String? = nil,
    resultSummary: String? = nil,
    failureCode: String? = nil,
    changedFiles: [String] = [],
    activity: [BridgeDesktopActivityRow] = [],
    conversation: [BridgeDesktopConversationEntry] = [],
    conversationState: BridgeDesktopConversationState? = nil,
    canInterrupt: Bool? = nil,
    canStop: Bool? = nil,
    canSteer: Bool? = nil,
    permissionRemediation: BridgeDesktopPermissionRemediationState? = nil,
    turnCount: Int = 1,
    canResume: Bool = false,
    canRestart: Bool = false,
    updatedAt: String
  ) {
    self.taskID = taskID
    self.sessionID = sessionID ?? taskID
    self.title = title
    self.projectName = projectName
    self.status = status
    self.isTerminal = isTerminal
    self.provider = provider
    self.providerID = providerID
    self.model = model
    self.permissionMode = permissionMode
    self.currentStep = currentStep
    self.resultSummary = resultSummary
    self.failureCode = failureCode
    self.changedFiles = changedFiles
    self.activity = activity
    self.conversation = conversation
    self.conversationState = conversationState
    self.canInterrupt = canInterrupt
    self.canStop = canStop
    self.canSteer = canSteer
    self.permissionRemediation = permissionRemediation
    self.turnCount = max(1, turnCount)
    self.canResume = canResume
    self.canRestart = canRestart
    self.updatedAt = updatedAt
  }
}
