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
    deadline: ContinuousClock.Instant
  ) async throws -> MCPServiceTaskSubmissionReceipt {
    try Self.checkDeadline(deadline)
    let prepared = try await prepareTaskSubmission(
      submission,
      sourceClientID: sourceClientID,
      source: source,
      deadline: deadline
    )
    let result = try await submitTaskWithAdmission(
      prepared.request,
      projectID: prepared.projectID
    )
    if source == .macOSApp,
      let submitted = try await tasks.task(id: result.task.id),
      submitted.state.status == .awaitingLocalApproval
    {
      try await approveAndStartTask(
        submitted.id,
        summary: "The local App submitted this provider invocation."
      )
    } else if try await settings.taskStartApprovalMode() == .auto,
      let submitted = try await tasks.task(id: result.task.id),
      submitted.state.status == .awaitingLocalApproval,
      submitted.requiresLocalStartApproval
    {
      try await approveAndStartTask(submitted.id, automatically: true)
    }
    let task = try await tasks.task(id: result.task.id)
    let latest = task ?? result.task
    return MCPServiceTaskSubmissionReceipt(
      taskID: latest.id.rawValue,
      status: latest.state.status.rawValue,
      reusedExistingTask: result.reusedExistingTask,
      localApprovalRequired: latest.state.status == .awaitingLocalApproval
    )
  }
}
