import BridgeAgentCore
import BridgeDomain
import BridgeSecurity
import BridgeServiceCore
import Foundation

extension ServiceExecutionCoordinator {
  private static func agentStartFailureSummary(_ error: Error, provider: String) -> String {
    ExecutionStartFailurePresentation.summary(error, provider: provider)
  }

  private static func agentStartFailureCode(_ error: Error) -> String {
    if case AgentRuntimeError.capabilityUnavailable(.readOnlyExecution) = error {
      return "agent_read_only_unavailable"
    }
    if case AgentRuntimeError.modelUnavailable = error {
      return "agent_model_unavailable"
    }
    return "agent_start_failed"
  }

  private func agentRuntimeBinding(for task: ServiceTaskRecord) async throws -> AgentRuntimeBinding?
  {
    switch AgentProviderID(rawValue: task.providerID) {
    case .deepSeekHarness:
      return try await tasks.agentRuntimeBinding(taskID: task.id)
        ?? AgentRuntimeBinding(connectionMode: .acp, requestID: task.id.rawValue)
    case .deepSeekHarnessDesktop:
      return try await tasks.agentRuntimeBinding(taskID: task.id)
    default:
      return nil
    }
  }

  func startAgentTask(
    _ task: ServiceTaskRecord,
    project: ServiceProjectRecord
  ) async throws {
    guard let runner = agentRunner else {
      throw ExecutionServiceError.processUnavailable
    }
    guard let installationID = task.installationID else {
      throw ExecutionServiceError.invalidRequest("installationID")
    }
    let workspaceChangeTracker: ServiceWorkspaceChangeTracker?
    let handle: AgentTaskRunHandle
    do {
      do {
        try project.root.validateCurrentIdentity()
      } catch {
        throw ExecutionServiceError.projectIdentityChanged(project.id)
      }
      let workspace = try await executionWorkspaceResolver?(task, project)
      try ensureStartIsActive(task.id)
      if let workspace {
        guard task.source == .mcpClient, task.sourceClientID.hasPrefix("embedded.dsh."),
          task.permissionMode == .full
        else { throw ExecutionServiceError.invalidRequest("isolatedWorkspace.owner") }
        try workspace.validate(projectRoot: project.root.canonicalPath)
      }
      let attachments = try await tasks.taskAttachments(taskID: task.id)
      let attachmentContents: [AgentImageContent]?
      if workspace != nil, !attachments.isEmpty {
        try project.root.validateCurrentIdentity()
        attachmentContents = try attachments.map { attachment in
          let image = try SecureProjectImageReader.read(
            attachment, projectRoot: project.root.canonicalPath)
          return try AgentImageContent(attachment: image.attachment, data: image.data)
        }
        try project.root.validateCurrentIdentity()
      } else {
        attachmentContents = nil
      }
      let brief = AgentTaskBrief(
        taskID: task.id,
        providerID: AgentProviderID(rawValue: task.providerID),
        installationID: AgentInstallationID(rawValue: installationID),
        projectID: task.projectID,
        projectRoot: project.root.canonicalPath,
        prompt: task.prompt,
        requestedSessionID: task.requestedThreadID,
        model: task.executionModel == serviceDefaultProviderExecutionModel
          ? nil : task.executionModel,
        effort: task.providerID == AgentProviderID.antigravity.rawValue
          || task.executionEffort == serviceDefaultProviderExecutionEffort
          ? nil : task.executionEffort,
        permissionMode: task.permissionMode,
        runtimeBinding: try await agentRuntimeBinding(for: task),
        networkAllowed: task.networkAllowed,
        attachments: attachments,
        attachmentContents: attachmentContents,
        selectedSkills: task.selectedSkills,
        isolatedWorkspace: workspace,
        nativeSubagentsAllowed: !(try await tasks.isEmbeddedDSHTask(task.id)),
        toolWriteGate: try await toolWriteGate(for: task)
      )
      workspaceChangeTracker = ServiceWorkspaceChangeTracker(
        projectRoot: workspace?.root.canonicalPath ?? project.root.canonicalPath
      )
      handle = try await withProcessOwnership(taskID: task.id) {
        try await runner.start(brief)
      }
    } catch {
      if !finishedRuns.contains(task.id), !isShuttingDown,
        await confirmOwnedProcessesStopped(taskID: task.id)
      {
        let conversationPersisted = await conversation.close(taskID: task.id)
        _ = try? await tasks.fail(
          taskID: task.id,
          failureCode: conversationPersisted
            ? Self.agentStartFailureCode(error) : "conversation_persistence_failed",
          summary: conversationPersisted
            ? Self.agentStartFailureSummary(error, provider: task.providerID)
            : "The task conversation could not be persisted."
        )
      }
      throw error
    }

    do {
      try ensureStartIsActive(task.id)
      let runID =
        handle.runID.flatMap { $0.isEmpty ? nil : $0 }
        ?? UUID().uuidString.lowercased()
      // The state model pairs session/run; when the provider has no stable
      // session concept the run identity doubles as the session reference.
      let sessionID = handle.sessionID.flatMap { $0.isEmpty ? nil : $0 } ?? runID
      _ = try await tasks.markAgentExecutionStarted(
        taskID: task.id,
        providerSessionID: sessionID,
        providerRunID: runID
      )
      activeAgentRuns[task.id] = ActiveAgentRun(
        providerID: task.providerID,
        installationID: installationID,
        providerSessionID: handle.sessionID,
        providerRunID: handle.runID,
        effectiveRunID: runID,
        interrupt: handle.interrupt,
        steer: handle.steer,
        interruptAndSteer: handle.interruptAndSteer,
        shutdown: handle.shutdown,
        resolveApproval: handle.resolveApproval,
        resolveUserInput: handle.resolveUserInput
      )
      if let workspaceChangeTracker {
        workspaceChangeTrackers[task.id] = workspaceChangeTracker
      }
      await conversation.appendUserMessage(taskID: task.id, content: task.prompt)
      try ensureStartIsActive(task.id)
    } catch {
      activeAgentRuns.removeValue(forKey: task.id)
      workspaceChangeTrackers.removeValue(forKey: task.id)
      await handle.shutdown()
      if !finishedRuns.contains(task.id), !isShuttingDown,
        await confirmOwnedProcessesStopped(taskID: task.id)
      {
        let conversationPersisted = await conversation.close(taskID: task.id)
        _ = try? await tasks.fail(
          taskID: task.id,
          failureCode: conversationPersisted
            ? Self.agentStartFailureCode(error) : "conversation_persistence_failed",
          summary: conversationPersisted
            ? Self.agentStartFailureSummary(error, provider: task.providerID)
            : "The task conversation could not be persisted."
        )
      }
      throw error
    }

    let events = handle.events
    collectors[task.id] = Task { [weak self] in
      do {
        for try await envelope in events {
          guard let self else { return }
          await self.consumeAgent(envelope, taskID: task.id)
        }
        await self?.agentStreamFinished(task.id, failure: nil)
      } catch {
        await self?.agentStreamFinished(task.id, failure: error)
      }
    }
  }

  private func consumeAgent(_ envelope: AgentEventEnvelope, taskID: TaskID) async {
    guard !finishedRuns.contains(taskID) else { return }
    do {
      try validateAgentEnvelope(envelope, taskID: taskID)
      switch envelope.event {
      case .content, .steerDispatched, .tool, .plan, .usage, .usageStatistics,
        .approvalAutomaticallyDenied:
        try await agentEventProcessor.process(envelope.event, taskID: taskID)

      case .approvalRequested(let approval):
        _ = try await registerAgentApproval(approval, taskID: taskID)

      case .userInputRequested(let request):
        _ = try await registerAgentUserInput(request, taskID: taskID)

      case .interactionsCancelled(let approvalIDs, let userInputIDs):
        try await cancelAgentInteractions(
          taskID: taskID, approvalIDs: approvalIDs, userInputIDs: userInputIDs)

      case .completed(let summary, let stopReason):
        try await finishAgentRun(taskID: taskID) {
          try await persistWorkspaceChanges(taskID: taskID)
          try await closeConversation(taskID: taskID)
          let current = try await requiredTask(taskID)
          return try await tasks.complete(
            taskID: taskID,
            resultSummary: summary.isEmpty ? "The agent run completed." : summary,
            changedFiles: current.state.changedFiles,
            eventSummary: Self.agentCompletionEventSummary(stopReason: stopReason)
          )
        }

      case .interrupted:
        try await finishAgentRun(taskID: taskID) {
          try await persistWorkspaceChanges(taskID: taskID)
          try await closeConversation(taskID: taskID)
          return try await tasks.interrupt(
            taskID: taskID,
            summary: "The agent confirmed that the run was interrupted."
          )
        }

      case .failed(let code, let summary):
        try await finishAgentRun(taskID: taskID) {
          try await persistWorkspaceChanges(taskID: taskID)
          await conversation.appendAgentMessage(taskID: taskID, content: summary)
          try await closeConversation(taskID: taskID)
          return try await tasks.fail(
            taskID: taskID,
            failureCode: code,
            summary: summary
          )
        }
      }
    } catch {
      finishedRuns.insert(taskID)
      workspaceChangeTrackers.removeValue(forKey: taskID)
      pendingAgentApprovals = pendingAgentApprovals.filter { $0.value.request.taskID != taskID }
      clearAgentUserInputs(taskID: taskID)
      await closeAgentRun(taskID: taskID)
      _ = await conversation.close(taskID: taskID)
      guard await confirmOwnedProcessesStopped(taskID: taskID) else { return }
      _ = try? await tasks.fail(
        taskID: taskID,
        failureCode: "agent_execution_failed",
        summary: Self.persistenceFailureSummary(error, provider: envelope.providerID.rawValue)
      )
    }
  }

  private func finishAgentRun(
    taskID: TaskID,
    transition: () async throws -> ServiceTaskRecord?
  ) async throws {
    guard !finishedRuns.contains(taskID) else { return }
    finishedRuns.insert(taskID)
    pendingAgentApprovals = pendingAgentApprovals.filter { $0.value.request.taskID != taskID }
    clearAgentUserInputs(taskID: taskID)
    await closeAgentRun(taskID: taskID)
    guard await confirmOwnedProcessesStopped(taskID: taskID) else { return }
    _ = try await transition()
  }

  private func agentStreamFinished(_ taskID: TaskID, failure: (any Error)?) async {
    collectors.removeValue(forKey: taskID)
    pendingAgentApprovals = pendingAgentApprovals.filter { $0.value.request.taskID != taskID }
    clearAgentUserInputs(taskID: taskID)
    guard finishedRuns.remove(taskID) == nil else { return }
    await closeAgentRun(taskID: taskID)
    guard await confirmOwnedProcessesStopped(taskID: taskID) else { return }
    try? await persistWorkspaceChanges(taskID: taskID)
    _ = await conversation.close(taskID: taskID)
    let summary: String
    let failureCode: String
    if let failure {
      failureCode = "agent_execution_failed"
      summary = Self.persistenceFailureSummary(failure, provider: "agent")
    } else {
      failureCode = "agent_stream_ended"
      summary = "The agent event stream ended before reporting a terminal result."
    }
    _ = try? await tasks.fail(
      taskID: taskID,
      failureCode: failureCode,
      summary: summary
    )
  }

  private func persistWorkspaceChanges(taskID: TaskID) async throws {
    guard let tracker = workspaceChangeTrackers.removeValue(forKey: taskID),
      let task = try await tasks.task(id: taskID)
    else {
      return
    }
    let observed = tracker.changedFiles()
    guard !observed.isEmpty else { return }
    let changedFiles = Array(Set(task.state.changedFiles + observed)).sorted()
    guard changedFiles != task.state.changedFiles else { return }
    _ = try await tasks.recordChangedFiles(
      taskID: taskID,
      relativePaths: changedFiles,
      summary: "The agent changed project files."
    )
  }

  private func validateAgentEnvelope(
    _ envelope: AgentEventEnvelope,
    taskID: TaskID
  ) throws {
    guard var run = activeAgentRuns[taskID] else {
      throw AgentRuntimeError.runMismatch
    }
    guard envelope.taskID == taskID,
      envelope.providerID.rawValue == run.providerID,
      envelope.providerSessionID == run.providerSessionID,
      envelope.providerRunID == run.providerRunID,
      run.lastSequence.map({ envelope.providerSequence > $0 }) ?? true
    else {
      throw AgentRuntimeError.malformedEvent("agent.binding")
    }
    run.lastSequence = envelope.providerSequence
    activeAgentRuns[taskID] = run
  }

  private static func agentCompletionEventSummary(stopReason: String?) -> String {
    guard let stopReason,
      !stopReason.isEmpty,
      stopReason.utf8.count <= 128,
      stopReason.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      return "The provider reported completion."
    }
    return "The provider reported completion with stop reason \(stopReason)."
  }
}
