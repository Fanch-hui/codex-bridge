import BridgeACP
import BridgeAgentCore
import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Crypto
import Foundation

extension ServiceEmbeddedDSHController {
  func subagent(_ input: ACPJSONValue) async throws -> ACPJSONValue {
    guard let payload = input.objectValue else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.subagent")
    }
    let rootID = try Self.requiredString(payload, "rootSessionID")
    let project = try await project(for: rootID)
    let operation = try Self.requiredString(payload, "operation")
    if operation == "results" {
      var results: [ACPJSONValue] = []
      for item in try await application.pendingEmbeddedDSHResults(parentSessionID: rootID) {
        let value: ACPJSONValue = .object([
          "childID": .string(item.childID), "requestID": .string(item.requestID),
          "taskID": .string(item.taskID.rawValue), "state": .string(item.status.rawValue),
          "output": item.resultSummary.map(ACPJSONValue.string) ?? .null,
          "error": item.failureCode.map(ACPJSONValue.string) ?? .null,
        ])
        results.append(
          try await enrichWorkspaceState(
            value, rootID: rootID, childID: item.childID,
            taskID: item.taskID.rawValue, state: item.status.rawValue))
      }
      return .object(["results": .array(results)])
    }
    let childID = try Self.requiredString(payload, "childID")
    switch operation {
    case "reserve":
      return try await reserveSubagentWorkspace(
        rootID: rootID, childID: childID,
        requestID: Self.requiredString(payload, "requestID"), projectID: project.id,
        installationID: payload["installationID"]?.stringValue)
    case "releaseReservation":
      return try await releaseSubagentWorkspaceReservation(
        rootID: rootID, childID: childID,
        requestID: Self.requiredString(payload, "requestID"), projectID: project.id)
    case "ack":
      try await application.acknowledgeEmbeddedDSHResult(
        parentSessionID: rootID, childID: childID,
        requestID: Self.requiredString(payload, "requestID"),
        taskID: TaskID(rawValue: Self.requiredString(payload, "taskID")))
      return .object([:])
    case "start":
      // Read-only preparation (provider and model checks) runs before the input gate so that
      // parallel starts only queue for the short submission step.
      let preparation = await prepareSubagentStart(payload, projectID: project.id)
      await inputGate.acquire()
      defer { inputGate.release() }
      try Task.checkCancellation()
      if let result = try await previousSubagentSubmission(
        payload, rootID: rootID, childID: childID)
      {
        return result
      }
      try await ensureSubagentRequestAdmitted(payload, rootID: rootID, childID: childID)
      return try await startSubagent(
        payload, rootID: rootID, childID: childID, projectID: project.id,
        preparation: preparation.get())
    case "probe":
      return try await probeSubagent(payload, rootID: rootID, childID: childID)
    case "get", "wait":
      let binding = try await child(rootID: rootID, childID: childID, allowPendingRecovery: true)
      let taskID = try await selectedSubagentTask(payload, rootID: rootID, binding: binding)
      let snapshot: MCPServiceTaskSnapshot
      if payload["operation"]?.stringValue == "wait" {
        snapshot = try await application.serviceWaitTask(
          taskID: taskID.rawValue, timeoutSeconds: 20, recentEventLimit: 6,
          deadline: .now.advanced(by: .seconds(25))
        ).task
      } else {
        snapshot = try await application.serviceTask(
          taskID: taskID.rawValue, recentEventLimit: 6, deadline: .now.advanced(by: .seconds(25)))
      }
      if let expectedRunID = payload["runID"]?.stringValue,
        expectedRunID != (snapshot.turnID ?? snapshot.providerRunID)
      {
        throw ServiceStoreError.invalidArgument("embedded_dsh.child_run_mismatch")
      }
      return try await subagentSnapshot(payload, rootID: rootID, binding: binding, task: snapshot)
    case "send":
      let value = try await sendSubagent(payload, rootID: rootID, childID: childID)
      var result = value.objectValue ?? [:]
      result["workspaceMode"] = .string(try await workspaceMode(rootID: rootID, childID: childID))
      if let reason = try await workspaceReason(rootID: rootID, childID: childID) {
        result["workspaceReason"] = .string(reason)
      }
      return .object(result)
    case "changes":
      return try await workspaceChanges(
        rootID: rootID, childID: childID, retry: payload["retryMerge"]?.boolValue == true,
        resolutions: payload["resolutions"])
    case "stop":
      let binding = try await child(rootID: rootID, childID: childID)
      if let taskID = binding.currentTaskID {
        let task = try await application.serviceTask(
          taskID: taskID.rawValue, recentEventLimit: 1, deadline: .now.advanced(by: .seconds(40)))
        try validateCurrentSubagentTask(
          payload, binding: binding, taskID: task.taskID, runID: task.turnID ?? task.providerRunID)
        try await application.serviceStopTask(
          taskID: taskID.rawValue, deadline: .now.advanced(by: .seconds(40)))
      }
      return .object(["state": .string("interrupted")])
    default: throw ServiceStoreError.invalidArgument("embedded_dsh.subagent_operation")
    }
  }

  private struct SubagentStartPreparation {
    let providerID: String
    let installationID: String?
    let model: String?
    let effort: String?
  }

  private func prepareSubagentStart(_ payload: [String: ACPJSONValue], projectID: ProjectID)
    async -> Result<SubagentStartPreparation, any Error>
  {
    do {
      let installationID = try Self.requiredString(payload, "installationID")
      let providerID = try await subagentProviderID(installationID: installationID)
      let submissionInstallationID = installationID == "codex" ? nil : installationID
      let (model, effort) = try await resolveSubagentModelOverrides(
        payload, projectID: projectID, providerID: providerID,
        installationID: submissionInstallationID, nativeSessionID: nil,
        deadline: .now.advanced(by: .seconds(40)))
      return .success(
        SubagentStartPreparation(
          providerID: providerID, installationID: submissionInstallationID,
          model: model, effort: effort))
    } catch {
      return .failure(error)
    }
  }

  private func startSubagent(
    _ payload: [String: ACPJSONValue], rootID: String, childID: String, projectID: ProjectID,
    preparation: SubagentStartPreparation
  ) async throws -> ACPJSONValue {
    try await submitSubagent(
      payload, rootID: rootID, childID: childID, projectID: projectID,
      providerID: preparation.providerID, installationID: preparation.installationID,
      nativeSessionID: nil, modelOverrides: (preparation.model, preparation.effort))
  }

  private func submitSubagent(
    _ payload: [String: ACPJSONValue], rootID: String, childID: String, projectID: ProjectID,
    providerID: String, installationID: String?, nativeSessionID: String?,
    originalFingerprint: String? = nil, modelOverrides: (model: String?, effort: String?)? = nil
  ) async throws -> ACPJSONValue {
    let requestID = try Self.requiredString(payload, "requestID")
    let prompt = try Self.requiredString(payload, "prompt")
    let attachmentPaths = try Self.subagentAttachmentPaths(payload)
    let fingerprint = try originalFingerprint ?? Self.subagentSubmissionFingerprint(payload)
    try await recordSubagentSubmission(
      fingerprint: fingerprint, requestID: requestID, rootID: rootID, childID: childID)
    guard let execution = try await application.embeddedDSHExecution(sessionID: rootID) else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.execution")
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(40))
    let (requestedModel, requestedEffort) =
      if let modelOverrides {
        modelOverrides
      } else {
        try await resolveSubagentModelOverrides(
          payload, projectID: projectID, providerID: providerID, installationID: installationID,
          nativeSessionID: nativeSessionID, deadline: deadline)
      }
    let workspace = try await prepareSubagentWorkspace(
      rootID: rootID, childID: childID, projectID: projectID, providerID: providerID,
      installationID: installationID,
      permissionMode: execution.permissionMode, continuation: nativeSessionID != nil)
    var taskPrompt = prompt
    if workspace.mode == "isolated" {
      taskPrompt +=
        "\n\nThis task runs in an isolated copy with controlled file tools. "
        + "Shell commands, child processes, and external MCP tools are unavailable. "
        + "Edit the files directly; the merge validation runs project checks and tests."
    }
    if !workspace.synchronizedPaths.isEmpty {
      let paths = try Self.json(.array(workspace.synchronizedPaths.map(ACPJSONValue.string)))
      taskPrompt +=
        "\n\nThe isolated workspace was synchronized with the project. Changed paths include: "
        + paths
    }
    if !workspace.repairPaths.isEmpty {
      let paths = try Self.json(.array(workspace.repairPaths.map(ACPJSONValue.string)))
      taskPrompt +=
        "\n\nResolve and remove every BRIDGE_CONFLICT marker in the workspace. Affected paths include: "
        + paths + ". An empty conflict version means the file was deleted."
    }
    let submission = MCPServiceTaskSubmission(
      projectID: projectID.rawValue, prompt: taskPrompt, threadID: nativeSessionID,
      providerID: providerID, installationID: installationID,
      executionModel: requestedModel,
      executionEffort: requestedEffort,
      modelOverride: requestedModel != nil || requestedEffort != nil,
      permissionMode: execution.permissionMode.rawValue, clientRequestID: requestID,
      queueIfBusy: false, attachmentPaths: attachmentPaths)
    let result = try await application.submitEmbeddedDSHSubagent(
      submission, parentSessionID: rootID, childID: childID,
      deadline: deadline)
    var receipt: [String: ACPJSONValue] = [
      "childID": .string(childID), "taskID": .string(result.taskID),
      "state": .string(result.status), "waitingForApproval": .bool(result.localApprovalRequired),
      "workspaceMode": .string(workspace.mode),
    ]
    if let reason = try await workspaceReason(rootID: rootID, childID: childID) {
      receipt["workspaceReason"] = .string(reason)
    }
    return .object(receipt)
  }

  private func resolveSubagentModelOverrides(
    _ payload: [String: ACPJSONValue], projectID: ProjectID, providerID: String,
    installationID: String?, nativeSessionID: String?, deadline: ContinuousClock.Instant
  ) async throws -> (model: String?, effort: String?) {
    let requestedModel = payload["model"]?.stringValue
    let requestedEffort = payload["effort"]?.stringValue
    guard nativeSessionID == nil, providerID != "codex", let installationID,
      requestedModel != nil || requestedEffort != nil,
      let catalog = try? await application.serviceAgentModels(
        installationID: installationID, projectID: projectID.rawValue, modelID: nil,
        forceRefresh: false, deadline: deadline),
      !catalog.models.isEmpty
    else { return (requestedModel, requestedEffort) }
    let defaults = try? await application.serviceAgentModelDefault(
      providerID: AgentProviderID(rawValue: providerID), deadline: deadline)
    let targetModelID =
      requestedModel ?? defaults?.model
      ?? catalog.models.first(where: { $0.isDefault == true })?.modelID
    guard let targetModelID else { return (requestedModel, requestedEffort) }
    guard let matched = catalog.models.first(where: { $0.modelID == targetModelID }) else {
      guard let requestedModel else { return (nil, requestedEffort) }
      let defaultHint = defaults?.model.map { " Configured default model: \($0)." } ?? ""
      throw AgentRuntimeError.modelUnavailable(
        "\(requestedModel).\(defaultHint) Omit model/effort to use the configured default, or call bridge_agent_models."
      )
    }
    guard let effort = requestedEffort else { return (requestedModel, nil) }
    if matched.reasoningEfforts.isEmpty { return (requestedModel, nil) }
    guard matched.reasoningEfforts.contains(effort) else {
      throw AgentRuntimeError.invalidRequest(
        "Model \(targetModelID) supports efforts: \(matched.reasoningEfforts.joined(separator: ", "))."
      )
    }
    return (requestedModel, effort)
  }

  private func child(rootID: String, childID: String, allowPendingRecovery: Bool = false)
    async throws
    -> EmbeddedDSHSubagentBinding
  {
    guard
      let binding = try await application.embeddedDSHSubagent(
        parentSessionID: rootID, childID: childID),
      binding.projectID == (try await project(for: rootID)).id
    else { throw ServiceStoreError.invalidArgument("embedded_dsh.child") }
    guard binding.currentStatus == .unknown else { return binding }
    do {
      try await recoverChild(binding)
    } catch {
      if allowPendingRecovery { return binding }
      throw error
    }
    return try await application.embeddedDSHSubagent(parentSessionID: rootID, childID: childID)
      ?? binding
  }

  func sendSubagent(
    _ payload: [String: ACPJSONValue], rootID: String, childID: String
  ) async throws -> ACPJSONValue {
    await inputGate.acquire()
    defer { inputGate.release() }
    try Task.checkCancellation()
    if let result = try await previousSubagentSubmission(payload, rootID: rootID, childID: childID)
    {
      return result
    }
    if let result = try await previousInputResult(payload, rootID: rootID, childID: childID) {
      return result
    }
    try await ensureSubagentRequestAdmitted(payload, rootID: rootID, childID: childID)
    let binding = try await child(rootID: rootID, childID: childID)
    guard let taskID = binding.currentTaskID else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.child_task")
    }
    let snapshot = try await application.serviceTask(
      taskID: taskID.rawValue, recentEventLimit: 1, deadline: .now.advanced(by: .seconds(40)))
    try validateCurrentSubagentTask(
      payload, binding: binding, taskID: snapshot.taskID,
      runID: snapshot.turnID ?? snapshot.providerRunID)
    if snapshot.waitPolicy.terminal {
      guard let nativeSessionID = binding.nativeSessionID else {
        throw ServiceStoreError.invalidArgument("embedded_dsh.child_session_unavailable")
      }
      var continuation = payload
      continuation["model"] = binding.executionModel.flatMap {
        $0 == serviceDefaultProviderExecutionModel ? nil : .string($0)
      }
      continuation["effort"] = binding.executionEffort.flatMap {
        $0 == serviceDefaultProviderExecutionEffort ? nil : .string($0)
      }
      return try await submitSubagent(
        continuation, rootID: rootID, childID: childID, projectID: binding.projectID,
        providerID: binding.providerID, installationID: binding.installationID,
        nativeSessionID: nativeSessionID,
        originalFingerprint: Self.subagentSubmissionFingerprint(payload))
    }
    return try await steerSubagent(payload, task: snapshot, rootID: rootID, childID: childID)
  }

  private func steerSubagent(
    _ payload: [String: ACPJSONValue], task: MCPServiceTaskSnapshot, rootID: String, childID: String
  ) async throws -> ACPJSONValue {
    let requestID = try Self.requiredString(payload, "requestID")
    let prompt = try Self.requiredString(payload, "prompt")
    guard try Self.subagentAttachmentPaths(payload).isEmpty else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.steer_attachments")
    }
    let key =
      "embedded_dsh.input." + Self.digest([rootID, childID, requestID].joined(separator: "\0"))
    let fingerprint = Self.digest(prompt)
    guard let turnID = task.turnID ?? task.providerRunID else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.child_not_running")
    }
    try await store.setSetting(
      ServiceSettingRecord(
        key: key,
        value: Self.json(
          .object([
            "fingerprint": .string(fingerprint), "taskID": .string(task.taskID),
            "runID": .string(turnID),
          ])),
        updatedAt: Date()))
    let receipt = try await application.serviceSteerTask(
      taskID: task.taskID, expectedTurnID: turnID, input: prompt, mode: .queued,
      deadline: .now.advanced(by: .seconds(40)))
    let result = ACPJSONValue.object([
      "taskID": .string(receipt.taskID), "state": .string(receipt.status),
    ])
    try await store.setSetting(
      ServiceSettingRecord(
        key: key,
        value: Self.json(
          .object([
            "fingerprint": .string(fingerprint), "taskID": .string(task.taskID),
            "runID": .string(turnID), "result": result,
          ])), updatedAt: Date()))
    return result
  }

  func previousInputResult(
    _ payload: [String: ACPJSONValue], rootID: String, childID: String
  ) async throws -> ACPJSONValue? {
    let requestID = try Self.requiredString(payload, "requestID")
    let prompt = try Self.requiredString(payload, "prompt")
    let key =
      "embedded_dsh.input." + Self.digest([rootID, childID, requestID].joined(separator: "\0"))
    guard let stored = try await store.setting(key: key) else { return nil }
    let previous = try JSONDecoder().decode(ACPJSONValue.self, from: Data(stored.value.utf8))
    let previousTaskID =
      previous["taskID"]?.stringValue ?? previous["result"]?["taskID"]?.stringValue
    let previousRunID = previous["runID"]?.stringValue
    guard previous["fingerprint"]?.stringValue == Self.digest(prompt),
      try Self.subagentAttachmentPaths(payload).isEmpty,
      previousTaskID == nil
        || payload["taskID"]?.stringValue.map({ $0 == previousTaskID }) != false,
      previousRunID == nil || payload["runID"]?.stringValue.map({ $0 == previousRunID }) != false
    else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.input_identity")
    }
    guard let result = previous["result"] else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.input_outcome_unknown")
    }
    return result
  }

  static func childState(_ task: MCPServiceTaskSnapshot, childID: String) throws
    -> ACPJSONValue
  {
    var state: [String: ACPJSONValue] = [
      "childID": .string(childID), "taskID": .string(task.taskID), "state": .string(task.status),
      "waitingForApproval": .bool(task.localApprovalRequired),
      "terminal": .bool(
        task.status != ServiceTaskStatus.unknown.rawValue && task.waitPolicy.terminal),
      "recentActivity": try value(task.recentActivity),
    ]
    if let output = task.resultSummary { state["output"] = .string(output) }
    if let error = task.failureCode { state["error"] = .string(error) }
    if let question = task.pendingUserInput { state["pendingUserInput"] = try value(question) }
    return .object(state)
  }

  static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
