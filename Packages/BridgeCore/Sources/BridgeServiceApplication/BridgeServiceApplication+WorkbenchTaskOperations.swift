import BridgeAgentCore
import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public func performWorkbenchTaskOperation(
    kind: String, operationID: String, inputJSON: String
  ) async throws -> String {
    let prepared: PreparedWorkbenchTaskOperation
    do {
      try Self.validateWorkbenchOperationID(operationID)
      prepared = try WorkbenchTaskOperationCodec.decode(
        PreparedWorkbenchTaskOperation.self, inputJSON)
    } catch {
      throw WorkbenchTaskOperationNotDispatched(cause: error)
    }
    if let recovered = try await reconcileWorkbenchTaskOperation(
      kind: kind, operationID: operationID, inputJSON: inputJSON)
    {
      return recovered
    }
    let current: WorkbenchTaskOperationBinding
    do {
      current = try await workbenchTaskBinding(kind: kind, request: prepared.request)
      guard current == prepared.binding else { throw BridgeMCPQueryError.contractRejected }
      switch kind {
      case "workbench.steer":
        guard current.controlID != nil, prepared.request.input != nil else {
          throw BridgeMCPQueryError.contractRejected
        }
      case "workbench.resume": break
      case "handoff.submit":
        guard prepared.request.providerID != nil, prepared.request.handoffID != nil,
          prepared.request.revision != nil
        else { throw BridgeMCPQueryError.contractRejected }
      default: throw BridgeMCPQueryError.contractRejected
      }
    } catch {
      throw WorkbenchTaskOperationNotDispatched(cause: error)
    }
    switch kind {
    case "workbench.steer":
      guard let expectedTurnID = current.controlID, let input = prepared.request.input else {
        throw BridgeMCPQueryError.contractRejected
      }
      let result = try await serviceSteerTask(
        taskID: current.taskID, expectedTurnID: expectedTurnID, input: input,
        mode: prepared.request.mode ?? .queued, deadline: .now.advanced(by: .seconds(60)))
      return try WorkbenchTaskOperationCodec.encode(
        WorkbenchTaskOperationReceipt(taskID: result.taskID, status: result.status))
    case "workbench.resume":
      return try await performWorkbenchResume(
        prepared, operationID: operationID, inputJSON: inputJSON)
    case "handoff.submit":
      guard let providerID = prepared.request.providerID,
        let handoffID = prepared.request.handoffID,
        let revision = prepared.request.revision
      else { throw BridgeMCPQueryError.contractRejected }
      let preview = try await serviceTaskHandoff(
        .init(
          action: .submit, sourceTaskID: current.taskID, providerID: providerID,
          handoffID: handoffID, expectedRevision: revision),
        deadline: .now.advanced(by: .seconds(60)))
      return try WorkbenchTaskOperationCodec.encode(
        WorkbenchTaskOperationReceipt(
          taskID: preview.targetTaskID, status: preview.phase, handoff: preview))
    default: throw BridgeMCPQueryError.contractRejected
    }
  }

  public func reconcileWorkbenchTaskOperation(
    kind: String, operationID: String, inputJSON: String
  ) async throws -> String? {
    try Self.validateWorkbenchOperationID(operationID)
    let prepared = try WorkbenchTaskOperationCodec.decode(
      PreparedWorkbenchTaskOperation.self, inputJSON)
    switch kind {
    case "workbench.steer": return nil
    case "workbench.resume":
      guard let target = try await tasks.workbenchTask(clientRequestID: operationID) else {
        return nil
      }
      try await validateRecoveredWorkbenchTask(
        target, binding: prepared.binding, request: prepared.request)
      return try WorkbenchTaskOperationCodec.encode(
        WorkbenchTaskOperationReceipt(
          taskID: target.id.rawValue,
          status: target.isQueued ? "queued" : target.state.status.rawValue))
    case "handoff.submit":
      guard let handoffID = prepared.request.handoffID,
        let record = try await tasks.handoff(id: handoffID), record.targetTaskID != nil
      else { return nil }
      guard record.packet.sourceTaskID == prepared.binding.taskID,
        record.preview.providerID == prepared.request.providerID,
        record.preview.revision == prepared.request.revision,
        record.targetFingerprint == prepared.binding.handoffFingerprint,
        record.packet.sourceRevision == prepared.binding.handoffSourceRevision
      else { throw BridgeMCPQueryError.contractRejected }
      let preview = try await handoffStatus(record)
      return try WorkbenchTaskOperationCodec.encode(
        WorkbenchTaskOperationReceipt(
          taskID: preview.targetTaskID, status: preview.phase, handoff: preview))
    default: throw BridgeMCPQueryError.contractRejected
    }
  }

  private func performWorkbenchResume(
    _ operation: PreparedWorkbenchTaskOperation, operationID: String, inputJSON: String
  ) async throws -> String {
    let binding = operation.binding
    let execution = WorkbenchResumeExecution(binding: binding, request: operation.request)
    let model = execution.submittedModel
    let submission = MCPServiceTaskSubmission(
      projectID: binding.projectID,
      prompt: Self.workbenchResumePrompt(operation.request.input),
      skillNames: operation.request.skillNames, threadID: binding.sessionID,
      providerID: binding.providerID, installationID: binding.installationID,
      executionModel: model, executionEffort: execution.submittedEffort,
      modelOverride: model != nil,
      permissionMode: execution.permissionMode.rawValue, clientRequestID: operationID,
      queueIfBusy: operation.request.queueIfBusy ?? false,
      attachmentPaths: operation.request.attachmentPaths)
    let admission: String
    do {
      admission = try await workspaceGate.beginTaskAdmission()
    } catch {
      throw WorkbenchTaskOperationNotDispatched(cause: error)
    }
    var submitted = false
    do {
      let deadline = ContinuousClock.now.advanced(by: .seconds(60))
      let target = try await prepareTaskSubmission(
        submission, sourceClientID: "macos.app", source: .macOSApp, deadline: deadline)
      try Self.validatePreparedWorkbenchResume(target, binding: binding, execution: execution)
      guard
        try await workbenchTaskBinding(kind: "workbench.resume", request: operation.request)
          == binding
      else {
        throw BridgeMCPQueryError.contractRejected
      }
      submitted = true
      let created = try await submitTaskWithAdmission(target.request, projectID: target.projectID)
      if let task = try await tasks.task(id: created.task.id),
        task.state.status == .awaitingLocalApproval, !task.isQueued
      {
        try await approveAndStartTask(
          task.id, summary: "The local App resumed this provider session.")
      }
      let latest = try await tasks.task(id: created.task.id) ?? created.task
      let receipt = try WorkbenchTaskOperationCodec.encode(
        WorkbenchTaskOperationReceipt(
          taskID: latest.id.rawValue,
          status: latest.isQueued ? "queued" : latest.state.status.rawValue))
      await workspaceGate.endTaskAdmission(token: admission)
      return receipt
    } catch {
      await workspaceGate.endTaskAdmission(token: admission)
      guard submitted else { throw WorkbenchTaskOperationNotDispatched(cause: error) }
      if let recovered = try await reconcileWorkbenchTaskOperation(
        kind: "workbench.resume", operationID: operationID, inputJSON: inputJSON)
      {
        return recovered
      }
      // Task creation is one store transaction keyed by the operation ID, so a failed
      // submission that left no task (for example a full project write slot) was never
      // dispatched and must not leave the session waiting on an unknown delivery.
      throw WorkbenchTaskOperationNotDispatched(cause: error)
    }
  }

  private static func validatePreparedWorkbenchResume(
    _ prepared: PreparedTaskSubmission, binding: WorkbenchTaskOperationBinding,
    execution: WorkbenchResumeExecution
  ) throws {
    let request = prepared.request
    guard prepared.projectID.rawValue == binding.projectID,
      request.providerID == binding.providerID,
      request.installationID == binding.installationID,
      request.requestedThreadID == binding.sessionID,
      execution.accepts(
        model: request.executionModel, effort: request.executionEffort,
        permission: request.permissionMode),
      request.accessMode == binding.accessMode,
      request.fastMode == binding.fastMode, request.attachments == binding.attachments,
      request.runtimeBinding?.connectionMode == binding.runtimeMode,
      request.runtimeBinding?.profileID == binding.runtimeProfileID
    else { throw BridgeMCPQueryError.contractRejected }
  }

  private func validateRecoveredWorkbenchTask(
    _ task: ServiceTaskRecord, binding: WorkbenchTaskOperationBinding,
    request: WorkbenchTaskOperationInput
  ) async throws {
    let prompt = Self.workbenchResumePrompt(request.input)
    let hasInjectedSkills =
      request.skillNames?.isEmpty == false
      && binding.providerID != "pi" && binding.providerID != "qoder"
    let promptMatches =
      hasInjectedSkills
      ? task.prompt.hasSuffix("\n\nUser task:\n" + prompt) : task.prompt == prompt
    let execution = WorkbenchResumeExecution(binding: binding, request: request)
    guard task.projectID.rawValue == binding.projectID, task.providerID == binding.providerID,
      task.installationID == binding.installationID, task.requestedThreadID == binding.sessionID,
      execution.accepts(
        model: task.executionModel, effort: task.executionEffort,
        permission: task.permissionMode),
      task.accessMode == binding.accessMode,
      task.fastMode == binding.fastMode, task.queueIfBusy == (request.queueIfBusy ?? false),
      promptMatches,
      try await tasks.taskAttachments(taskID: task.id) == binding.attachments
    else { throw BridgeMCPQueryError.contractRejected }
    let runtime = try await runtimeBindingForTask(task)
    guard runtime?.connectionMode == binding.runtimeMode,
      runtime?.profileID == binding.runtimeProfileID
    else { throw BridgeMCPQueryError.contractRejected }
  }

  private static func workbenchResumePrompt(_ input: String?) -> String {
    let text = input?.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.flatMap { $0.isEmpty ? nil : $0 } ?? "继续执行未完成的任务"
  }

  private static func validateWorkbenchOperationID(_ operationID: String) throws {
    guard !operationID.isEmpty, operationID.utf8.count <= 128,
      operationID == operationID.trimmingCharacters(in: .whitespacesAndNewlines),
      operationID.rangeOfCharacter(from: .controlCharacters) == nil
    else { throw BridgeMCPQueryError.contractRejected }
  }
}
