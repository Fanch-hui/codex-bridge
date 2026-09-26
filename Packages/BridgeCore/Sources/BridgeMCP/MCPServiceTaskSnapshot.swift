import BridgeAgentCore
import Foundation

public struct MCPServiceTaskSnapshot: Codable, Equatable, Sendable {
  public let usage: AgentUsageStatistics?
  public let pendingUserInput: MCPServiceTaskUserInput?
  public let taskID: String
  public let projectID: String
  public let prompt: String?
  public let source: String?
  public let sourceClientID: String?
  public let status: String
  public let providerID: String?
  public let installationID: String?
  public let executionModel: String?
  public let executionEffort: String?
  public let threadID: String?
  public let turnID: String?
  public let providerSessionID: String?
  public let providerRunID: String?
  public let permissionMode: String?
  public let networkAccess: Bool
  public let currentStep: String?
  public let changedFiles: [String]
  public let attachmentPaths: [String]
  public let recentEvents: [MCPServiceTaskEvent]
  public let recentActivity: [MCPServiceTaskActivity]
  public let recentActivityAvailable: Bool
  public let supervisorStatus: String
  public let supervisorSummary: String?
  public let localApprovalRequired: Bool
  public let resultSummary: String?
  public let failureCode: String?
  public let updatedAt: String
  public let queuePosition: Int?
  public let queueOccupantTaskID: String?
  public let queueRequestedAt: String?
  public let waitPolicy: MCPServiceTaskWaitPolicy

  public init(
    taskID: String,
    projectID: String,
    prompt: String? = nil,
    source: String? = nil,
    sourceClientID: String? = nil,
    status: String,
    providerID: String? = nil,
    installationID: String? = nil,
    executionModel: String? = nil,
    executionEffort: String? = nil,
    threadID: String? = nil,
    turnID: String? = nil,
    providerSessionID: String? = nil,
    providerRunID: String? = nil,
    permissionMode: String? = nil,
    networkAccess: Bool = false,
    currentStep: String? = nil,
    changedFiles: [String] = [],
    attachmentPaths: [String] = [],
    recentEvents: [MCPServiceTaskEvent] = [],
    recentActivity: [MCPServiceTaskActivity] = [],
    recentActivityAvailable: Bool = true,
    supervisorStatus: String,
    supervisorSummary: String? = nil,
    localApprovalRequired: Bool,
    resultSummary: String? = nil,
    failureCode: String? = nil,
    updatedAt: String,
    queuePosition: Int? = nil,
    queueOccupantTaskID: String? = nil,
    queueRequestedAt: String? = nil,
    waitPolicy: MCPServiceTaskWaitPolicy? = nil,
    usage: AgentUsageStatistics? = nil,
    pendingUserInput: MCPServiceTaskUserInput? = nil
  ) {
    self.usage = usage
    self.pendingUserInput = pendingUserInput
    self.taskID = taskID
    self.projectID = projectID
    self.prompt = prompt
    self.source = source
    self.sourceClientID = sourceClientID
    self.status = status
    self.providerID = providerID
    self.installationID = installationID
    self.executionModel = executionModel
    self.executionEffort = executionEffort
    self.threadID = threadID
    self.turnID = turnID
    self.providerSessionID = providerSessionID
    self.providerRunID = providerRunID
    self.permissionMode = permissionMode
    self.networkAccess = networkAccess
    self.currentStep = currentStep
    self.changedFiles = changedFiles
    self.attachmentPaths = attachmentPaths
    self.recentEvents = recentEvents
    self.recentActivity = recentActivity
    self.recentActivityAvailable = recentActivityAvailable
    self.supervisorStatus = supervisorStatus
    self.supervisorSummary = supervisorSummary
    self.localApprovalRequired = localApprovalRequired
    self.resultSummary = resultSummary
    self.failureCode = failureCode
    self.updatedAt = updatedAt
    self.queuePosition = queuePosition
    self.queueOccupantTaskID = queueOccupantTaskID
    self.queueRequestedAt = queueRequestedAt
    self.waitPolicy =
      waitPolicy
      ?? (pendingUserInput == nil
        ? MCPServiceTaskWaitPolicy.forTask(
          status: status,
          recentActivityAvailable: recentActivityAvailable,
          recentActivityCount: recentActivity.count
        )
        : MCPServiceTaskWaitPolicy.forUserInput())
  }

  private enum CodingKeys: String, CodingKey {
    case usage
    case pendingUserInput = "pending_user_input"
    case taskID = "task_id"
    case projectID = "project_id"
    case prompt
    case source
    case sourceClientID = "source_client_id"
    case status
    case providerID = "provider_id"
    case installationID = "installation_id"
    case executionModel = "execution_model"
    case executionEffort = "execution_effort"
    case threadID = "thread_id"
    case turnID = "turn_id"
    case providerSessionID = "provider_session_id"
    case providerRunID = "provider_run_id"
    case permissionMode = "permission_mode"
    case networkAccess = "network_access"
    case currentStep = "current_step"
    case changedFiles = "changed_files"
    case attachmentPaths = "attachment_paths"
    case recentEvents = "recent_events"
    case recentActivity = "recent_activity"
    case recentActivityAvailable = "recent_activity_available"
    case supervisorStatus = "supervisor_status"
    case supervisorSummary = "supervisor_summary"
    case localApprovalRequired = "local_approval_required"
    case resultSummary = "result_summary"
    case failureCode = "failure_code"
    case updatedAt = "updated_at"
    case queuePosition = "queue_position"
    case queueOccupantTaskID = "queue_occupant_task_id"
    case queueRequestedAt = "queue_requested_at"
    case waitPolicy = "wait_policy"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    usage = try container.decodeIfPresent(AgentUsageStatistics.self, forKey: .usage)
    pendingUserInput = try container.decodeIfPresent(
      MCPServiceTaskUserInput.self, forKey: .pendingUserInput)
    taskID = try container.decode(String.self, forKey: .taskID)
    projectID = try container.decode(String.self, forKey: .projectID)
    prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
    source = try container.decodeIfPresent(String.self, forKey: .source)
    sourceClientID = try container.decodeIfPresent(String.self, forKey: .sourceClientID)
    status = try container.decode(String.self, forKey: .status)
    providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
    installationID = try container.decodeIfPresent(String.self, forKey: .installationID)
    executionModel = try container.decodeIfPresent(String.self, forKey: .executionModel)
    executionEffort = try container.decodeIfPresent(String.self, forKey: .executionEffort)
    threadID = try container.decodeIfPresent(String.self, forKey: .threadID)
    turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
    providerSessionID = try container.decodeIfPresent(String.self, forKey: .providerSessionID)
    providerRunID = try container.decodeIfPresent(String.self, forKey: .providerRunID)
    permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
    networkAccess = try container.decodeIfPresent(Bool.self, forKey: .networkAccess) ?? false
    currentStep = try container.decodeIfPresent(String.self, forKey: .currentStep)
    changedFiles = try container.decodeIfPresent([String].self, forKey: .changedFiles) ?? []
    attachmentPaths = try container.decodeIfPresent([String].self, forKey: .attachmentPaths) ?? []
    recentEvents =
      try container.decodeIfPresent([MCPServiceTaskEvent].self, forKey: .recentEvents) ?? []
    recentActivity =
      try container.decodeIfPresent([MCPServiceTaskActivity].self, forKey: .recentActivity) ?? []
    recentActivityAvailable =
      try container.decodeIfPresent(Bool.self, forKey: .recentActivityAvailable) ?? true
    supervisorStatus = try container.decode(String.self, forKey: .supervisorStatus)
    supervisorSummary = try container.decodeIfPresent(String.self, forKey: .supervisorSummary)
    localApprovalRequired = try container.decode(Bool.self, forKey: .localApprovalRequired)
    resultSummary = try container.decodeIfPresent(String.self, forKey: .resultSummary)
    failureCode = try container.decodeIfPresent(String.self, forKey: .failureCode)
    updatedAt = try container.decode(String.self, forKey: .updatedAt)
    queuePosition = try container.decodeIfPresent(Int.self, forKey: .queuePosition)
    queueOccupantTaskID = try container.decodeIfPresent(String.self, forKey: .queueOccupantTaskID)
    queueRequestedAt = try container.decodeIfPresent(String.self, forKey: .queueRequestedAt)
    waitPolicy =
      try container.decodeIfPresent(MCPServiceTaskWaitPolicy.self, forKey: .waitPolicy)
      ?? (pendingUserInput == nil
        ? MCPServiceTaskWaitPolicy.forTask(
          status: status,
          recentActivityAvailable: recentActivityAvailable,
          recentActivityCount: recentActivity.count
        )
        : MCPServiceTaskWaitPolicy.forUserInput())
  }
}
