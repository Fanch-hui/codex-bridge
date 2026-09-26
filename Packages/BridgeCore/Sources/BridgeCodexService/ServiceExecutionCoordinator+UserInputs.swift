import BridgeAgentCore
import BridgeDomain
import BridgeSecurity
import BridgeServiceCore
import Foundation

extension ServiceExecutionCoordinator {
  public func pendingUserInputs(taskID: TaskID? = nil) async -> [ExecutionApprovalRequest] {
    let approvals = await pendingApprovals(taskID: taskID)
    return approvals.filter { $0.kind == .userInput }
  }

  public func resolveUserInput(
    taskID: TaskID,
    inputID: String,
    response: AgentUserInputResponse
  ) async throws {
    if let pending = pendingAgentUserInputs[inputID] {
      guard pending.request.taskID == taskID else {
        throw ExecutionServiceError.bindingMismatch
      }
      try await resolveAgentUserInput(pending, response: response)
      return
    }
    try await resolveCodexUserInput(taskID: taskID, inputID: inputID, response: response)
  }

  func pendingAgentUserInputApprovals(taskID: TaskID? = nil) async -> [ExecutionApprovalRequest] {
    await expireAgentUserInputs()
    return pendingAgentUserInputs.values
      .filter { taskID == nil || $0.request.taskID == taskID }
      .compactMap { try? executionApproval(from: $0.request, approvalID: $0.approvalID) }
  }

  func registerAgentUserInput(
    _ request: AgentUserInputRequest,
    taskID: TaskID
  ) async throws -> ServiceTaskRecord {
    guard request.taskID == taskID,
      let run = activeAgentRuns[taskID],
      run.providerID == request.binding.providerID.rawValue,
      run.installationID == request.binding.installationID.rawValue,
      run.providerSessionID == request.binding.providerSessionID,
      run.providerRunID == request.binding.providerRunID,
      run.resolveUserInput != nil
    else {
      throw ExecutionServiceError.bindingMismatch
    }
    guard
      !pendingAgentUserInputs.values.contains(where: {
        $0.request.taskID == taskID && $0.request.inputID == request.inputID
      })
    else {
      throw AgentRuntimeError.malformedEvent("agent.userInput.duplicate")
    }
    let pending = PendingAgentUserInput(
      approvalID: "agent-user-input-" + UUID().uuidString.lowercased(),
      request: request,
      createdAt: Date()
    )
    _ = try executionApproval(from: request, approvalID: pending.approvalID)
    let details = try persistedDetails(for: request)
    let updated = try await tasks.markWaitingForAgentUserInput(
      taskID: taskID,
      questionCount: request.questions.count,
      details: details
    )
    guard !finishedRuns.contains(taskID),
      activeAgentRuns[taskID]?.effectiveRunID == run.effectiveRunID
    else {
      throw AgentRuntimeError.runMismatch
    }
    pendingAgentUserInputs[pending.approvalID] = pending
    scheduleAgentUserInputTimeout(pending)
    tasks.changes.publish()
    return updated
  }

  func resolveAgentUserInput(
    _ pending: PendingAgentUserInput,
    response: AgentUserInputResponse
  ) async throws {
    let request = pending.request
    guard let run = activeAgentRuns[request.taskID],
      run.providerID == request.binding.providerID.rawValue,
      run.installationID == request.binding.installationID.rawValue,
      run.providerSessionID == request.binding.providerSessionID,
      run.providerRunID == request.binding.providerRunID,
      let resolveUserInput = run.resolveUserInput
    else {
      throw ExecutionServiceError.bindingMismatch
    }
    let cancelled: Bool
    switch response {
    case .answers(let answers):
      try Self.validate(answers, for: request.questions)
      cancelled = false
    case .cancelled:
      cancelled = true
    }
    let expiresAfter = TimeInterval(request.timeoutSeconds ?? Int(agentApprovalLifetime))
    guard Date().timeIntervalSince(pending.createdAt) <= expiresAfter else {
      pendingAgentUserInputs.removeValue(forKey: pending.approvalID)
      agentUserInputTimeouts.removeValue(forKey: pending.approvalID)?.cancel()
      try await expireAgentUserInput(pending)
      throw ExecutionServiceError.approvalUnavailable(request.inputID)
    }
    pendingAgentUserInputs.removeValue(forKey: pending.approvalID)
    agentUserInputTimeouts.removeValue(forKey: pending.approvalID)?.cancel()
    do {
      _ = try await tasks.resumeAfterAgentUserInput(
        taskID: request.taskID,
        cancelled: cancelled
      )
    } catch {
      await failAgentUserInput(
        taskID: request.taskID,
        code: "agent_user_input_state_failed",
        summary: "The provider question response could not be recorded."
      )
      throw error
    }
    do {
      try await resolveUserInput(request.inputID, response)
      tasks.changes.publish()
    } catch {
      await failAgentUserInput(
        taskID: request.taskID,
        code: "agent_user_input_response_failed",
        summary: "The provider question response could not be delivered."
      )
      throw ExecutionServiceError.processUnavailable
    }
  }

  private func resolveCodexUserInput(
    taskID: TaskID,
    inputID: String,
    response: AgentUserInputResponse
  ) async throws {
    guard
      let request = await execution.pendingApprovals(taskID: taskID)
        .first(where: { $0.id == inputID && $0.kind == .userInput })
    else {
      throw ExecutionServiceError.approvalUnavailable(inputID)
    }
    let decision: LocalApprovalDecision
    let answers: [String: [String]]?
    switch response {
    case .answers(let values):
      try Self.validate(values, for: request.questions)
      decision = .allow
      answers = values
    case .cancelled:
      decision = .deny
      answers = nil
    }
    try await execution.respondToApproval(
      taskID: taskID,
      approvalID: inputID,
      decision: decision,
      answers: answers
    )
    _ = try await tasks.resumeAfterAgentUserInput(
      taskID: taskID,
      cancelled: decision == .deny
    )
    await execution.finalizeApproval(taskID: taskID, approvalID: inputID, committed: true)
    presentedCodexApprovals[taskID]?.remove(inputID)
    tasks.changes.publish()
  }

  private func executionApproval(
    from request: AgentUserInputRequest,
    approvalID: String
  ) throws -> ExecutionApprovalRequest {
    let sessionID = request.binding.providerSessionID ?? request.taskID.rawValue
    let runID = request.binding.providerRunID ?? request.inputID
    let binding = try ExecutionBinding(
      threadID: "agent:\(sessionID)",
      turnID: "agent:\(runID)"
    )
    return try ExecutionApprovalRequest(
      id: approvalID,
      taskID: request.taskID,
      binding: binding,
      itemID: request.providerItemID,
      kind: .userInput,
      title: request.title,
      summary: request.summary,
      availableDecisions: [.allow, .deny],
      questions: request.questions.map { question in
        ExecutionUserInputQuestion(
          id: question.id,
          header: question.header,
          question: question.question,
          inputType: question.kind.rawValue,
          isOther: question.allowsCustomText,
          isSecret: question.isSecret,
          allowsMultiple: question.allowsMultiple,
          isRequired: question.isRequired,
          options: question.options.map {
            ExecutionUserInputOption(label: $0.label, description: $0.description)
          }
        )
      },
      userInputTimeoutSeconds: request.timeoutSeconds
    )
  }

  private func persistedDetails(for request: AgentUserInputRequest) throws -> String {
    let data = try JSONEncoder().encode(request)
    guard let serialized = String(data: data, encoding: .utf8) else {
      throw ExecutionServiceError.invalidRequest("userInput.encoding")
    }
    return OutboundContentSecurity.redactedSecrets(
      serialized,
      maximumUTF8Bytes: 64 * 1_024
    )
  }

  func clearAgentUserInputs(taskID: TaskID? = nil) {
    let ids = pendingAgentUserInputs.keys.filter { inputID in
      guard let taskID else { return true }
      return pendingAgentUserInputs[inputID]?.request.taskID == taskID
    }
    for inputID in ids {
      agentUserInputTimeouts.removeValue(forKey: inputID)?.cancel()
      pendingAgentUserInputs.removeValue(forKey: inputID)
    }
  }

}
