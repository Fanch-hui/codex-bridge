import BridgeAgentCore
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
  public let usage: AgentUsageStatistics?
  public let currentStep: String?
  public let resultSummary: String?
  public let failureCode: String?
  public let changedFiles: [String]
  public let attachmentPaths: [String]?
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
  public let queuePosition: Int?
  public let queueOccupantTaskID: String?
  public let queueRequestedAt: String?
  public let handoffPrompt: String?
  public let handoffProviders: [BridgeDesktopChoice]?
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
    usage: AgentUsageStatistics? = nil,
    resultSummary: String? = nil,
    failureCode: String? = nil,
    changedFiles: [String] = [],
    attachmentPaths: [String]? = nil,
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
    queuePosition: Int? = nil,
    queueOccupantTaskID: String? = nil,
    queueRequestedAt: String? = nil,
    handoffPrompt: String? = nil,
    handoffProviders: [BridgeDesktopChoice]? = nil,
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
    self.usage = usage
    self.resultSummary = resultSummary
    self.failureCode = failureCode
    self.changedFiles = changedFiles
    self.attachmentPaths = attachmentPaths
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
    self.queuePosition = queuePosition
    self.queueOccupantTaskID = queueOccupantTaskID
    self.queueRequestedAt = queueRequestedAt
    self.handoffPrompt = handoffPrompt
    self.handoffProviders = handoffProviders
    self.updatedAt = updatedAt
  }
}
