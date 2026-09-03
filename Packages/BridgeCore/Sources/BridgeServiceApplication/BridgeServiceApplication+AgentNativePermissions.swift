import BridgeAgentCore
import BridgeDomain
import BridgeServiceCore

public struct ServiceAgentPermissionRemediation: Equatable, Sendable {
  public let taskID: TaskID
  public let messageKey: String
  public let installationID: AgentInstallationID
  public let candidate: AgentNativePermissionRemediation
  public let settingsRevision: String?

  public init(
    taskID: TaskID,
    messageKey: String,
    installationID: AgentInstallationID,
    candidate: AgentNativePermissionRemediation,
    settingsRevision: String?
  ) {
    self.taskID = taskID
    self.messageKey = messageKey
    self.installationID = installationID
    self.candidate = candidate
    self.settingsRevision = settingsRevision
  }
}

extension BridgeServiceApplication {
  public func serviceAgentNativePermissionPolicy(
    installationID: AgentInstallationID,
    deadline: ContinuousClock.Instant
  ) async throws -> AgentNativePermissionPolicySnapshot {
    try Self.checkDeadline(deadline)
    let snapshot = try await requiredAgentRegistry().nativePermissionPolicy(
      installationID: installationID
    )
    try Self.checkDeadline(deadline)
    return snapshot
  }

  public func serviceUpdateAgentNativePermissionPolicy(
    installationID: AgentInstallationID,
    mutation: AgentNativePermissionMutation,
    expectedRevision: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> AgentNativePermissionPolicySnapshot {
    try Self.checkDeadline(deadline)
    let snapshot = try await requiredAgentRegistry().updateNativePermissionPolicy(
      installationID: installationID,
      mutation: mutation,
      expectedRevision: expectedRevision
    )
    try Self.checkDeadline(deadline)
    return snapshot
  }

  public func serviceAgentPermissionRemediation(
    taskID: TaskID,
    messageKey: String,
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceAgentPermissionRemediation {
    try Self.checkDeadline(deadline)
    let (task, message, installationID) = try await remediationContext(
      taskID: taskID,
      messageKey: messageKey
    )
    let registry = try requiredAgentRegistry()
    guard
      let candidate = try await registry.nativePermissionRemediation(
        installationID: installationID,
        toolName: message.toolName ?? "",
        toolArguments: message.toolArguments ?? ""
      )
    else {
      throw AgentNativePermissionPolicyError.remediationUnavailable
    }
    let policy = try await registry.nativePermissionPolicy(
      installationID: installationID
    )
    try Self.checkDeadline(deadline)
    return ServiceAgentPermissionRemediation(
      taskID: task.id,
      messageKey: message.key,
      installationID: installationID,
      candidate: candidate,
      settingsRevision: policy.revision
    )
  }

  public func serviceApplyAgentPermissionRemediation(
    taskID: TaskID,
    messageKey: String,
    candidateID: String,
    expectedRevision: String?,
    deadline: ContinuousClock.Instant
  ) async throws -> AgentNativePermissionPolicySnapshot {
    let remediation = try await serviceAgentPermissionRemediation(
      taskID: taskID,
      messageKey: messageKey,
      deadline: deadline
    )
    guard remediation.candidate.candidateID == candidateID else {
      throw AgentNativePermissionPolicyError.remediationUnavailable
    }
    guard remediation.settingsRevision == expectedRevision else {
      throw AgentNativePermissionPolicyError.revisionConflict
    }
    let policy = try await requiredAgentRegistry().nativePermissionPolicy(
      installationID: remediation.installationID
    )
    guard
      !policy.rules.contains(where: {
        $0.action == remediation.candidate.action
          && $0.target == remediation.candidate.target
          && ($0.effect == .ask || $0.effect == .deny)
      })
    else {
      throw AgentNativePermissionPolicyError.ruleInvalid
    }
    let updated = try await requiredAgentRegistry().updateNativePermissionPolicy(
      installationID: remediation.installationID,
      mutation: .addRule(
        effect: .allow,
        action: remediation.candidate.action,
        target: remediation.candidate.target
      ),
      expectedRevision: expectedRevision
    )
    try Self.checkDeadline(deadline)
    return updated
  }

  private func remediationContext(
    taskID: TaskID,
    messageKey: String
  ) async throws -> (
    task: ServiceTaskRecord,
    message: ServiceTaskMessageRecord,
    installationID: AgentInstallationID
  ) {
    guard let task = try await tasks.task(id: taskID),
      task.state.status == .failed,
      task.state.failureCode == "antigravity_permission_denied",
      task.providerID == AgentProviderID.antigravity.rawValue,
      let rawInstallationID = task.installationID,
      let message = try await tasks.message(taskID: taskID, key: messageKey),
      message.taskID == taskID,
      message.kind == .toolCall,
      message.toolStatus == "declined",
      message.toolName != nil,
      message.toolArguments != nil
    else {
      throw AgentNativePermissionPolicyError.remediationUnavailable
    }
    return (
      task,
      message,
      AgentInstallationID(rawValue: rawInstallationID)
    )
  }
}
