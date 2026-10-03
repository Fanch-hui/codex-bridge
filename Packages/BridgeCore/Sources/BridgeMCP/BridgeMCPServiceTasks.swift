import Foundation

public struct MCPServiceTaskEvent: Codable, Equatable, Sendable {
  public let sequence: Int64
  public let kind: String
  public let summary: String
  public let occurredAt: String

  public init(sequence: Int64, kind: String, summary: String, occurredAt: String) {
    self.sequence = sequence
    self.kind = kind
    self.summary = summary
    self.occurredAt = occurredAt
  }

  private enum CodingKeys: String, CodingKey {
    case sequence = "seq"
    case kind
    case summary
    case occurredAt = "occurred_at"
  }
}

public struct MCPServiceTaskActivity: Codable, Equatable, Sendable {
  public let sequence: Int64
  public let kind: String
  public let summary: String
  public let occurredAt: String
  public let toolName: String?
  public let toolStatus: String?

  public init(
    sequence: Int64,
    kind: String,
    summary: String,
    occurredAt: String,
    toolName: String? = nil,
    toolStatus: String? = nil
  ) {
    self.sequence = sequence
    self.kind = kind
    self.summary = summary
    self.occurredAt = occurredAt
    self.toolName = toolName
    self.toolStatus = toolStatus
  }

  private enum CodingKeys: String, CodingKey {
    case sequence = "seq"
    case kind
    case summary
    case occurredAt = "occurred_at"
    case toolName = "tool_name"
    case toolStatus = "tool_status"
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sequence = try container.decode(Int64.self, forKey: .sequence)
    kind = try container.decode(String.self, forKey: .kind)
    summary = try container.decode(String.self, forKey: .summary)
    occurredAt = try container.decode(String.self, forKey: .occurredAt)
    toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
    toolStatus = try container.decodeIfPresent(String.self, forKey: .toolStatus)
  }
}

public struct MCPServiceTaskSubmission: Codable, Equatable, Sendable {
  public let projectID: String?
  public let prompt: String
  public let skillName: String?
  public let skillNames: [String]?
  public let threadID: String?
  public let providerID: String?
  public let installationID: String?
  public let executionModel: String?
  public let executionEffort: String?
  public let modelOverride: Bool?
  public let supervisorModel: String?
  public let supervisorEffort: String?
  public let permissionMode: String?
  /// Whether a remote client explicitly derived `permission_mode` from the
  /// user's request. The parser supplies `false` when the marker is absent;
  /// `nil` is retained for in-process callers that predate this field.
  public let permissionModeOverride: Bool?
  public let networkAccess: Bool
  public let acceptanceCriteria: [String]
  public let clientRequestID: String?
  public let queueIfBusy: Bool?
  public let attachmentPaths: [String]?
  public let attachmentSourceTaskID: String?

  public init(
    projectID: String? = nil,
    prompt: String,
    skillName: String? = nil,
    skillNames: [String]? = nil,
    threadID: String? = nil,
    providerID: String? = nil,
    installationID: String? = nil,
    executionModel: String? = nil,
    executionEffort: String? = nil,
    modelOverride: Bool? = nil,
    supervisorModel: String? = nil,
    supervisorEffort: String? = nil,
    permissionMode: String? = nil,
    permissionModeOverride: Bool? = nil,
    networkAccess: Bool = false,
    acceptanceCriteria: [String] = [],
    clientRequestID: String? = nil,
    queueIfBusy: Bool? = nil,
    attachmentPaths: [String]? = nil,
    attachmentSourceTaskID: String? = nil
  ) {
    self.projectID = projectID
    self.prompt = prompt
    self.skillName = skillName
    self.skillNames = skillNames
    self.threadID = threadID
    self.providerID = providerID
    self.installationID = installationID
    self.executionModel = executionModel
    self.executionEffort = executionEffort
    self.modelOverride = modelOverride
    self.supervisorModel = supervisorModel
    self.supervisorEffort = supervisorEffort
    self.permissionMode = permissionMode
    self.permissionModeOverride = permissionModeOverride
    self.networkAccess = networkAccess
    self.acceptanceCriteria = acceptanceCriteria
    self.clientRequestID = clientRequestID
    self.queueIfBusy = queueIfBusy
    self.attachmentPaths = attachmentPaths
    self.attachmentSourceTaskID = attachmentSourceTaskID
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case prompt
    case skillName = "skill_name"
    case skillNames = "skill_names"
    case threadID = "thread_id"
    case providerID = "provider_id"
    case installationID = "installation_id"
    case executionModel = "execution_model"
    case executionEffort = "execution_effort"
    case modelOverride = "model_override"
    case supervisorModel = "supervisor_model"
    case supervisorEffort = "supervisor_effort"
    case permissionMode = "permission_mode"
    case permissionModeOverride = "permission_mode_override"
    case networkAccess = "network_access"
    case acceptanceCriteria = "acceptance_criteria"
    case clientRequestID = "client_request_id"
    case queueIfBusy = "queue_if_busy"
    case attachmentPaths = "attachment_paths"
    case attachmentSourceTaskID = "attachment_source_task_id"
  }
}

public struct MCPServiceTaskSubmissionReceipt: Codable, Equatable, Sendable {
  public let taskID: String
  public let status: String
  public let reusedExistingTask: Bool
  public let localApprovalRequired: Bool

  public init(
    taskID: String,
    status: String,
    reusedExistingTask: Bool,
    localApprovalRequired: Bool
  ) {
    self.taskID = taskID
    self.status = status
    self.reusedExistingTask = reusedExistingTask
    self.localApprovalRequired = localApprovalRequired
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case status
    case reusedExistingTask = "reused_existing_task"
    case localApprovalRequired = "local_approval_required"
  }
}

public struct MCPServiceTaskMutationReceipt: Codable, Equatable, Sendable {
  public let taskID: String
  public let status: String
  public let accepted: Bool

  public init(taskID: String, status: String, accepted: Bool) {
    self.taskID = taskID
    self.status = status
    self.accepted = accepted
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case status
    case accepted
  }
}

public enum MCPTaskSteerMode: String, Codable, CaseIterable, Equatable, Sendable {
  case queued
  case interruptCurrentThenContinue = "interrupt-current-then-continue"
}
