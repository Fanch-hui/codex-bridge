import BridgeAgentCore
import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  /// Explicit non-Codex submissions resolve against the user-registered agent
  /// installations. Provider-specific task constraints live in the shared
  /// service policy registry; adapter capabilities are checked by the runner.
  func prepareAgentSubmission(
    _ submission: MCPServiceTaskSubmission,
    providerRaw: String,
    project: ServiceProjectRecord,
    sourceClientID: String,
    source: ServiceTaskSource,
    workbenchPermissionMode: ServicePermissionMode?,
    deadline: ContinuousClock.Instant
  ) async throws -> PreparedTaskSubmission {
    let context = try await resolveAgentSubmissionContext(
      submission: submission, providerRaw: providerRaw, project: project,
      workbenchPermissionMode: workbenchPermissionMode, deadline: deadline)
    let previousTask = try await agentContinuationSource(
      submission: submission, policy: context.policy, registry: context.registry,
      providerID: context.policy.providerID, record: context.record, project: project)
    let attachmentSourceTask = try await agentAttachmentSource(
      submission: submission, source: source, providerID: context.policy.providerID,
      record: context.record, project: project)
    let model = try await resolveAgentSubmissionModel(context: context, project: project)
    let selectedSkills = try await selectedSkillSnapshots(
      for: submission,
      project: project,
      deadline: deadline,
      previousTask: previousTask ?? attachmentSourceTask
    )
    let prompt = try await taskPrompt(
      for: submission,
      projectID: project.id.rawValue,
      deadline: deadline
    )
    let attachments = try await agentSubmissionAttachments(
      submission: submission, sourceTaskRecord: attachmentSourceTask,
      providerID: context.policy.providerID, record: context.record, project: project,
      model: model.descriptor)
    return PreparedTaskSubmission(
      projectID: project.id,
      request: ServiceTaskRequest(
        projectID: project.id,
        source: source,
        sourceClientID: source == .mcpClient ? sourceClientID : "",
        clientRequestID: submission.clientRequestID,
        prompt: prompt,
        requestedThreadID: submission.threadID,
        providerID: context.policy.providerID.rawValue,
        installationID: context.record.id.rawValue,
        selectionMode: .explicit,
        executionModel: model.executionModel,
        executionEffort: model.executionEffort,
        permissionMode: context.permission,
        accessMode: .requestApproval,
        queueIfBusy: submission.queueIfBusy == true,
        attachments: attachments,
        selectedSkills: selectedSkills,
        runtimeBinding: context.runtimeBinding
      )
    )
  }

  static func validatedAgentModel(_ model: String?) throws -> String? {
    guard let model else { return nil }
    let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 256,
      !trimmed.contains("\0"),
      trimmed.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    return trimmed
  }

  static func selectAgentInstallation(
    requested: String?,
    from selectable: [ServiceAgentInstallationRecord]
  ) throws -> ServiceAgentInstallationRecord {
    if let requested {
      guard let record = selectable.first(where: { $0.id.rawValue == requested }) else {
        throw BridgeMCPQueryError.unavailable
      }
      return record
    }
    guard let record = selectable.first else {
      throw BridgeMCPQueryError.unavailable
    }
    return record
  }
}
