import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  struct PreparedTaskSubmission {
    let projectID: ProjectID
    let request: ServiceTaskRequest
  }

  public func serviceSubmitTask(
    _ submission: MCPServiceTaskSubmission,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskSubmissionReceipt {
    try await serviceSubmitTask(
      submission,
      invocationContext: MCPInvocationContext(clientID: .chatGPT),
      deadline: deadline
    )
  }

  public func serviceSubmitTask(
    _ submission: MCPServiceTaskSubmission,
    invocationContext: MCPInvocationContext,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskSubmissionReceipt {
    try await submitTask(
      submission,
      source: .mcpClient,
      sourceClientID: invocationContext.clientID.rawValue,
      deadline: deadline
    )
  }

  func serviceSubmitTaskFromLocalApp(
    _ submission: MCPServiceTaskSubmission,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskSubmissionReceipt {
    try await submitTask(
      submission,
      source: .macOSApp,
      sourceClientID: "macos.app",
      deadline: deadline
    )
  }

  private func submitTask(
    _ submission: MCPServiceTaskSubmission,
    source: ServiceTaskSource,
    sourceClientID: String,
    deadline: ContinuousClock.Instant,
    embeddedDSHSubagent: EmbeddedDSHSubagentIdentity? = nil
  ) async throws -> MCPServiceTaskSubmissionReceipt {
    let admissionToken = try await workspaceGate.beginTaskAdmission()
    do {
      try Self.checkDeadline(deadline)
      let prepared = try await prepareTaskSubmission(
        submission,
        sourceClientID: sourceClientID,
        source: source,
        deadline: deadline,
        embeddedDSH: embeddedDSHSubagent != nil
      )
      let request: ServiceTaskRequest
      if let identity = embeddedDSHSubagent,
        let binding = try await tasks.embeddedDSHSubagent(
          parentSessionID: identity.parentSessionID, childID: identity.childID)
      {
        request = try Self.frozenEmbeddedDSHRequest(
          prepared.request, submission: submission, binding: binding)
      } else {
        request = prepared.request
      }
      let result = try await submitTaskWithAdmission(
        request,
        projectID: prepared.projectID,
        embeddedDSHSubagent: embeddedDSHSubagent
      )
      if source == .macOSApp,
        let submitted = try await tasks.task(id: result.task.id),
        submitted.state.status == .awaitingLocalApproval,
        !submitted.isQueued
      {
        try await approveAndStartTask(
          submitted.id,
          summary: "The local App submitted this provider invocation."
        )
      } else if embeddedDSHSubagent != nil,
        !result.reusedExistingTask,
        let submitted = try await tasks.task(id: result.task.id),
        submitted.state.status == .awaitingLocalApproval,
        !submitted.isQueued
      {
        try await approveAndStartTask(
          submitted.id,
          summary: "The Workbench delegated this subagent invocation.",
          startInBackground: true
        )
      } else if embeddedDSHSubagent == nil,
        try await settings.taskStartApprovalMode() == .auto,
        let submitted = try await tasks.task(id: result.task.id),
        submitted.state.status == .awaitingLocalApproval,
        !submitted.isQueued,
        submitted.requiresLocalStartApproval
      {
        try await approveAndStartTask(
          submitted.id,
          automatically: true,
          startInBackground: source.isRemoteMCPOrigin
        )
      }
      let task = try await tasks.task(id: result.task.id)
      let latest = task ?? result.task
      await workspaceGate.endTaskAdmission(token: admissionToken)
      return MCPServiceTaskSubmissionReceipt(
        taskID: latest.id.rawValue,
        status: latest.state.status.rawValue,
        reusedExistingTask: result.reusedExistingTask,
        localApprovalRequired: latest.state.status == .awaitingLocalApproval
          && !latest.isQueued
      )
    } catch {
      await workspaceGate.endTaskAdmission(token: admissionToken)
      throw error
    }
  }

  public func submitEmbeddedDSHSubagent(
    _ submission: MCPServiceTaskSubmission,
    parentSessionID: String,
    childID: String,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskSubmissionReceipt {
    guard submission.projectID != nil, submission.clientRequestID != nil,
      submission.queueIfBusy != true
    else { throw BridgeMCPQueryError.contractRejected }
    let identity = EmbeddedDSHSubagentIdentity(parentSessionID: parentSessionID, childID: childID)
    return try await submitTask(
      submission,
      source: .mcpClient,
      sourceClientID: identity.sourceClientID,
      deadline: deadline,
      embeddedDSHSubagent: identity
    )
  }

  private static func frozenEmbeddedDSHRequest(
    _ request: ServiceTaskRequest,
    submission: MCPServiceTaskSubmission,
    binding: EmbeddedDSHSubagentBinding
  ) throws -> ServiceTaskRequest {
    guard let model = binding.executionModel, let effort = binding.executionEffort else {
      throw ServiceStoreError.invalidArgument("dsh.subagentTaskRemoved")
    }
    if submission.modelOverride == true {
      if submission.executionModel != nil, request.executionModel != model {
        throw ServiceStoreError.invalidArgument("dsh.subagentModel")
      }
      if submission.executionEffort != nil, request.executionEffort != effort {
        throw ServiceStoreError.invalidArgument("dsh.subagentEffort")
      }
    }
    return ServiceTaskRequest(
      projectID: request.projectID, source: request.source, sourceClientID: request.sourceClientID,
      clientRequestID: request.clientRequestID, prompt: request.prompt,
      requestedThreadID: request.requestedThreadID, providerID: request.providerID,
      installationID: request.installationID, selectionMode: request.selectionMode,
      executionModel: model, executionEffort: effort, supervisorModel: request.supervisorModel,
      supervisorEffort: request.supervisorEffort, permissionMode: request.permissionMode,
      accessMode: request.accessMode, fastMode: request.fastMode, queueIfBusy: request.queueIfBusy,
      attachments: request.attachments, selectedSkills: request.selectedSkills,
      runtimeBinding: request.runtimeBinding
    )
  }
}
