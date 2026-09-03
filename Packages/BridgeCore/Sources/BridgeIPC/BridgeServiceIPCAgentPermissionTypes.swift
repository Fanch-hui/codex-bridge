import Foundation

public struct IPCAgentNativePermissionPolicyRequest: Codable, Equatable, Sendable {
  public let installationID: String

  public init(installationID: String) {
    self.installationID = installationID
  }

  private enum CodingKeys: String, CodingKey {
    case installationID = "installation_id"
  }
}

public struct IPCAgentNativePermissionRuleSummary: Codable, Equatable, Sendable {
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
    requiresConfirmation: Bool
  ) {
    self.ruleID = ruleID
    self.effect = effect
    self.action = action
    self.target = target
    self.isEditable = isEditable
    self.isRedacted = isRedacted
    self.requiresConfirmation = requiresConfirmation
  }

  private enum CodingKeys: String, CodingKey {
    case ruleID = "rule_id"
    case effect
    case action
    case target
    case isEditable = "is_editable"
    case isRedacted = "is_redacted"
    case requiresConfirmation = "requires_confirmation"
  }
}

public struct IPCAgentNativePermissionModeSummary: Codable, Equatable, Sendable {
  public let modeID: String
  public let displayName: String
  public let requiresConfirmation: Bool

  public init(modeID: String, displayName: String, requiresConfirmation: Bool) {
    self.modeID = modeID
    self.displayName = displayName
    self.requiresConfirmation = requiresConfirmation
  }

  private enum CodingKeys: String, CodingKey {
    case modeID = "mode_id"
    case displayName = "display_name"
    case requiresConfirmation = "requires_confirmation"
  }
}

public struct IPCAgentNativePermissionPolicyResponse: Codable, Equatable, Sendable {
  public let providerID: String
  public let installationID: String
  public let toolPermission: String
  public let availableModes: [IPCAgentNativePermissionModeSummary]
  public let availableActions: [String]
  public let rules: [IPCAgentNativePermissionRuleSummary]
  public let revision: String?
  public let warnings: [String]

  public init(
    providerID: String,
    installationID: String,
    toolPermission: String,
    availableModes: [IPCAgentNativePermissionModeSummary],
    availableActions: [String],
    rules: [IPCAgentNativePermissionRuleSummary],
    revision: String?,
    warnings: [String]
  ) {
    self.providerID = providerID
    self.installationID = installationID
    self.toolPermission = toolPermission
    self.availableModes = availableModes
    self.availableActions = availableActions
    self.rules = rules
    self.revision = revision
    self.warnings = warnings
  }

  private enum CodingKeys: String, CodingKey {
    case providerID = "provider_id"
    case installationID = "installation_id"
    case toolPermission = "tool_permission"
    case availableModes = "available_modes"
    case availableActions = "available_actions"
    case rules
    case revision
    case warnings
  }
}

public enum IPCAgentNativePermissionMutationOperation: String, Codable, Sendable {
  case setToolPermission = "set_tool_permission"
  case addRule = "add_rule"
  case replaceRule = "replace_rule"
  case removeRule = "remove_rule"
}

public struct IPCAgentNativePermissionMutationRequest: Codable, Equatable, Sendable {
  public let installationID: String
  public let expectedRevision: String?
  public let operation: IPCAgentNativePermissionMutationOperation
  public let toolPermission: String?
  public let ruleID: String?
  public let effect: String?
  public let action: String?
  public let target: String?

  public init(
    installationID: String,
    expectedRevision: String?,
    operation: IPCAgentNativePermissionMutationOperation,
    toolPermission: String? = nil,
    ruleID: String? = nil,
    effect: String? = nil,
    action: String? = nil,
    target: String? = nil
  ) {
    self.installationID = installationID
    self.expectedRevision = expectedRevision
    self.operation = operation
    self.toolPermission = toolPermission
    self.ruleID = ruleID
    self.effect = effect
    self.action = action
    self.target = target
  }

  private enum CodingKeys: String, CodingKey {
    case installationID = "installation_id"
    case expectedRevision = "expected_revision"
    case operation
    case toolPermission = "tool_permission"
    case ruleID = "rule_id"
    case effect
    case action
    case target
  }
}

public struct IPCAgentPermissionRemediationRequest: Codable, Equatable, Sendable {
  public let taskID: String
  public let messageKey: String

  public init(taskID: String, messageKey: String) {
    self.taskID = taskID
    self.messageKey = messageKey
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case messageKey = "message_key"
  }
}

public struct IPCAgentPermissionRemediationResponse: Codable, Equatable, Sendable {
  public let taskID: String
  public let messageKey: String
  public let installationID: String
  public let candidateID: String
  public let action: String
  public let target: String
  public let displayRule: String
  public let requiresConfirmation: Bool
  public let settingsRevision: String?

  public init(
    taskID: String,
    messageKey: String,
    installationID: String,
    candidateID: String,
    action: String,
    target: String,
    displayRule: String,
    requiresConfirmation: Bool,
    settingsRevision: String?
  ) {
    self.taskID = taskID
    self.messageKey = messageKey
    self.installationID = installationID
    self.candidateID = candidateID
    self.action = action
    self.target = target
    self.displayRule = displayRule
    self.requiresConfirmation = requiresConfirmation
    self.settingsRevision = settingsRevision
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case messageKey = "message_key"
    case installationID = "installation_id"
    case candidateID = "candidate_id"
    case action
    case target
    case displayRule = "display_rule"
    case requiresConfirmation = "requires_confirmation"
    case settingsRevision = "settings_revision"
  }
}

public struct IPCAgentPermissionRemediationApplyRequest: Codable, Equatable, Sendable {
  public let taskID: String
  public let messageKey: String
  public let candidateID: String
  public let expectedRevision: String?

  public init(
    taskID: String,
    messageKey: String,
    candidateID: String,
    expectedRevision: String?
  ) {
    self.taskID = taskID
    self.messageKey = messageKey
    self.candidateID = candidateID
    self.expectedRevision = expectedRevision
  }

  private enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case messageKey = "message_key"
    case candidateID = "candidate_id"
    case expectedRevision = "expected_revision"
  }
}
