import Foundation

public enum AgentNativePermissionEffect: String, Codable, CaseIterable, Sendable {
  case allow
  case ask
  case deny
}

public struct AgentNativePermissionModeDescriptor: Codable, Equatable, Sendable {
  public let id: String
  public let displayName: String
  public let requiresConfirmation: Bool

  public init(id: String, displayName: String, requiresConfirmation: Bool = false) throws {
    try AgentValidation.identifier(id, field: "nativePermission.mode.id", maximumBytes: 128)
    try AgentValidation.text(
      displayName,
      field: "nativePermission.mode.displayName",
      maximumBytes: 256
    )
    self.id = id
    self.displayName = displayName
    self.requiresConfirmation = requiresConfirmation
  }
}

public struct AgentNativePermissionRuleSnapshot: Codable, Equatable, Sendable {
  public let id: String
  public let effect: AgentNativePermissionEffect
  public let action: String
  public let target: String
  public let isEditable: Bool
  public let isRedacted: Bool
  public let requiresConfirmation: Bool

  public init(
    id: String,
    effect: AgentNativePermissionEffect,
    action: String,
    target: String,
    isEditable: Bool,
    isRedacted: Bool,
    requiresConfirmation: Bool = false
  ) throws {
    try AgentValidation.identifier(id, field: "nativePermission.rule.id", maximumBytes: 128)
    try AgentValidation.identifier(
      action,
      field: "nativePermission.rule.action",
      maximumBytes: 128
    )
    try AgentValidation.streamText(
      target,
      field: "nativePermission.rule.target",
      maximumBytes: 4 * 1_024
    )
    self.id = id
    self.effect = effect
    self.action = action
    self.target = target
    self.isEditable = isEditable
    self.isRedacted = isRedacted
    self.requiresConfirmation = requiresConfirmation
  }
}

public struct AgentNativePermissionPolicySnapshot: Codable, Equatable, Sendable {
  public let providerID: AgentProviderID
  public let installationID: AgentInstallationID
  public let toolPermission: String
  public let availableModes: [AgentNativePermissionModeDescriptor]
  public let availableActions: [String]
  public let rules: [AgentNativePermissionRuleSnapshot]
  public let revision: String?
  public let warnings: [String]

  public init(
    providerID: AgentProviderID,
    installationID: AgentInstallationID,
    toolPermission: String,
    availableModes: [AgentNativePermissionModeDescriptor],
    availableActions: [String],
    rules: [AgentNativePermissionRuleSnapshot],
    revision: String?,
    warnings: [String] = []
  ) throws {
    try AgentValidation.identifier(
      providerID.rawValue,
      field: "nativePermission.providerID",
      maximumBytes: 128
    )
    try AgentValidation.identifier(
      installationID.rawValue,
      field: "nativePermission.installationID",
      maximumBytes: 256
    )
    try AgentValidation.identifier(
      toolPermission,
      field: "nativePermission.toolPermission",
      maximumBytes: 128
    )
    guard !availableModes.isEmpty, availableModes.count <= 32,
      Set(availableModes.map(\.id)).count == availableModes.count,
      availableActions.count <= 128,
      Set(availableActions).count == availableActions.count,
      rules.count <= 1_536,
      Set(rules.map(\.id)).count == rules.count,
      warnings.count <= 64
    else {
      throw AgentRuntimeError.invalidRequest("nativePermission.snapshot")
    }
    for action in availableActions {
      try AgentValidation.identifier(
        action,
        field: "nativePermission.availableAction",
        maximumBytes: 128
      )
    }
    try AgentValidation.optionalIdentifier(
      revision,
      field: "nativePermission.revision",
      maximumBytes: 128
    )
    for warning in warnings {
      try AgentValidation.text(
        warning,
        field: "nativePermission.warning",
        maximumBytes: 1_024
      )
    }
    self.providerID = providerID
    self.installationID = installationID
    self.toolPermission = toolPermission
    self.availableModes = availableModes
    self.availableActions = availableActions
    self.rules = rules
    self.revision = revision
    self.warnings = warnings
  }
}

public enum AgentNativePermissionMutation: Equatable, Sendable {
  case setToolPermission(String)
  case addRule(effect: AgentNativePermissionEffect, action: String, target: String)
  case replaceRule(
    id: String,
    effect: AgentNativePermissionEffect,
    action: String,
    target: String
  )
  case removeRule(id: String)
}

public struct AgentNativePermissionRemediation: Codable, Equatable, Sendable {
  public let candidateID: String
  public let action: String
  public let target: String
  public let displayRule: String
  public let requiresConfirmation: Bool

  public init(
    candidateID: String,
    action: String,
    target: String,
    displayRule: String,
    requiresConfirmation: Bool
  ) throws {
    try AgentValidation.identifier(
      candidateID,
      field: "nativePermission.remediation.id",
      maximumBytes: 128
    )
    try AgentValidation.identifier(
      action,
      field: "nativePermission.remediation.action",
      maximumBytes: 128
    )
    try AgentValidation.streamText(
      target,
      field: "nativePermission.remediation.target",
      maximumBytes: 4 * 1_024
    )
    try AgentValidation.text(
      displayRule,
      field: "nativePermission.remediation.displayRule",
      maximumBytes: 4 * 1_024
    )
    self.candidateID = candidateID
    self.action = action
    self.target = target
    self.displayRule = displayRule
    self.requiresConfirmation = requiresConfirmation
  }
}

public enum AgentNativePermissionPolicyError: Error, Equatable, Sendable {
  case unavailable
  case revisionConflict
  case settingsInvalid
  case settingsUnsafe
  case ruleInvalid
  case remediationUnavailable
}

public protocol AgentNativePermissionPolicyManaging: Sendable {
  func snapshot(
    installation: AgentInstallation
  ) async throws -> AgentNativePermissionPolicySnapshot

  func update(
    installation: AgentInstallation,
    mutation: AgentNativePermissionMutation,
    expectedRevision: String?
  ) async throws -> AgentNativePermissionPolicySnapshot

  func remediation(
    toolName: String,
    toolArguments: String
  ) async -> AgentNativePermissionRemediation?
}

extension AgentNativePermissionPolicyManaging {
  public func remediation(
    toolName _: String,
    toolArguments _: String
  ) async -> AgentNativePermissionRemediation? {
    nil
  }
}
