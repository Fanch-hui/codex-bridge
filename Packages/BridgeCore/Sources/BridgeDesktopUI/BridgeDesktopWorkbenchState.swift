import Foundation

public struct BridgeDesktopTaskRow: Codable, Equatable, Sendable {
  public let taskID: String
  public let sessionID: String
  public let title: String
  public let projectID: String
  public let projectName: String
  public let source: String
  public let provider: String
  public let providerID: String
  public let status: String
  public let updatedAt: String
  public let turnCount: Int
  public let selected: Bool
  public let isRunning: Bool
  public let isActive: Bool
  public let canInterrupt: Bool
  public let canStop: Bool
  public let canSteer: Bool
  public let canResume: Bool
  public let canRestart: Bool
  public let canDelete: Bool

  public init(
    taskID: String,
    sessionID: String? = nil,
    title: String,
    projectID: String,
    projectName: String,
    source: String,
    provider: String,
    providerID: String = "codex",
    status: String,
    updatedAt: String,
    turnCount: Int = 1,
    selected: Bool = false,
    isRunning: Bool = false,
    isActive: Bool = false,
    canInterrupt: Bool = false,
    canStop: Bool = false,
    canSteer: Bool = false,
    canResume: Bool = false,
    canRestart: Bool = false,
    canDelete: Bool = false
  ) {
    self.taskID = taskID
    self.sessionID = sessionID ?? taskID
    self.title = title
    self.projectID = projectID
    self.projectName = projectName
    self.source = source
    self.provider = provider
    self.providerID = providerID
    self.status = status
    self.updatedAt = updatedAt
    self.turnCount = max(1, turnCount)
    self.selected = selected
    self.isRunning = isRunning
    self.isActive = isActive
    self.canInterrupt = canInterrupt
    self.canStop = canStop
    self.canSteer = canSteer
    self.canResume = canResume
    self.canRestart = canRestart
    self.canDelete = canDelete
  }
}

public struct BridgeDesktopApprovalRow: Codable, Equatable, Sendable {
  public let approvalID: String
  public let taskID: String?
  public let projectID: String?
  public let isDirect: Bool
  public let kind: String
  public let title: String
  public let summary: String
  public let displayCommand: String?
  public let relativePaths: [String]
  public let reason: String?
  public let decisionOptions: [String]
  public let canAllow: Bool
  public let canDeny: Bool
  public let resolving: Bool
  public let oneTimeToolAutoApprovalAvailable: Bool?

  public init(
    approvalID: String,
    taskID: String? = nil,
    projectID: String? = nil,
    isDirect: Bool = false,
    kind: String,
    title: String,
    summary: String,
    displayCommand: String? = nil,
    relativePaths: [String] = [],
    reason: String? = nil,
    decisionOptions: [String] = [],
    canAllow: Bool = true,
    canDeny: Bool = true,
    resolving: Bool = false,
    oneTimeToolAutoApprovalAvailable: Bool? = nil
  ) {
    self.approvalID = approvalID
    self.taskID = taskID
    self.projectID = projectID
    self.isDirect = isDirect
    self.kind = kind
    self.title = title
    self.summary = summary
    self.displayCommand = displayCommand
    self.relativePaths = relativePaths
    self.reason = reason
    self.decisionOptions = decisionOptions
    self.canAllow = canAllow
    self.canDeny = canDeny
    self.resolving = resolving
    self.oneTimeToolAutoApprovalAvailable = oneTimeToolAutoApprovalAvailable
  }
}

public struct BridgeDesktopPermissionRemediationState: Codable, Equatable, Sendable {
  public let messageKey: String
  public let installationID: String?
  public let candidateID: String?
  public let action: String?
  public let target: String?
  public let displayRule: String?
  public let requiresConfirmation: Bool
  public let isLoading: Bool
  public let isApplying: Bool
  public let didApply: Bool
  public let errorMessage: String?

  public init(
    messageKey: String,
    installationID: String? = nil,
    candidateID: String? = nil,
    action: String? = nil,
    target: String? = nil,
    displayRule: String? = nil,
    requiresConfirmation: Bool = false,
    isLoading: Bool = false,
    isApplying: Bool = false,
    didApply: Bool = false,
    errorMessage: String? = nil
  ) {
    self.messageKey = messageKey
    self.installationID = installationID
    self.candidateID = candidateID
    self.action = action
    self.target = target
    self.displayRule = displayRule
    self.requiresConfirmation = requiresConfirmation
    self.isLoading = isLoading
    self.isApplying = isApplying
    self.didApply = didApply
    self.errorMessage = errorMessage
  }
}

public struct BridgeDesktopTaskDetail: Codable, Equatable, Sendable {
  public let taskID: String
  public let sessionID: String
  public let title: String
  public let projectName: String
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
    self.permissionRemediation = permissionRemediation
    self.turnCount = max(1, turnCount)
    self.canResume = canResume
    self.canRestart = canRestart
    self.updatedAt = updatedAt
  }
}

public struct BridgeDesktopWorkbenchState: Codable, Equatable, Sendable {
  public let header: BridgeDesktopPageHeader
  public let projects: [BridgeDesktopChoice]
  public let selectedProjectID: String?
  public let permissionMode: String
  public let permissionOptions: [BridgeDesktopChoice]
  public let tasks: [BridgeDesktopTaskRow]
  public let selectedTaskID: String?
  public let selectedTask: BridgeDesktopTaskDetail?
  public let approvals: [BridgeDesktopApprovalRow]
  public let steerModes: [BridgeDesktopChoice]
  public let browser: BridgeDesktopBrowserSlot
  public let projectStatus: String?
  public let projectStatusTone: String?
  public let engineStatus: String?

  public init(
    header: BridgeDesktopPageHeader,
    projects: [BridgeDesktopChoice] = [],
    selectedProjectID: String? = nil,
    permissionMode: String = "workspace-write",
    permissionOptions: [BridgeDesktopChoice] = [],
    tasks: [BridgeDesktopTaskRow] = [],
    selectedTaskID: String? = nil,
    selectedTask: BridgeDesktopTaskDetail? = nil,
    approvals: [BridgeDesktopApprovalRow] = [],
    steerModes: [BridgeDesktopChoice] = [],
    browser: BridgeDesktopBrowserSlot = .init(),
    projectStatus: String? = nil,
    projectStatusTone: String? = nil,
    engineStatus: String? = nil
  ) {
    self.header = header
    self.projects = projects
    self.selectedProjectID = selectedProjectID
    self.permissionMode = permissionMode
    self.permissionOptions = permissionOptions
    self.tasks = tasks
    self.selectedTaskID = selectedTaskID
    self.selectedTask = selectedTask
    self.approvals = approvals
    self.steerModes = steerModes
    self.browser = browser
    self.projectStatus = projectStatus
    self.projectStatusTone = projectStatusTone
    self.engineStatus = engineStatus
  }
}
