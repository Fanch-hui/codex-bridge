import BridgeACP
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
      return .object([
        "results": .array(
          try await application.pendingEmbeddedDSHResults(parentSessionID: rootID).map {
            .object([
              "childID": .string($0.childID), "requestID": .string($0.requestID),
              "taskID": .string($0.taskID.rawValue), "state": .string($0.status.rawValue),
              "output": $0.resultSummary.map(ACPJSONValue.string) ?? .null,
              "error": $0.failureCode.map(ACPJSONValue.string) ?? .null,
            ])
          })
      ])
    }
    let childID = try Self.requiredString(payload, "childID")
    switch operation {
    case "ack":
      try await application.acknowledgeEmbeddedDSHResult(
        parentSessionID: rootID, childID: childID,
        requestID: Self.requiredString(payload, "requestID"),
        taskID: TaskID(rawValue: Self.requiredString(payload, "taskID")))
      return .object([:])
    case "start":
      return try await startSubagent(
        payload, rootID: rootID, childID: childID, projectID: project.id)
    case "get", "wait":
      let binding = try await child(rootID: rootID, childID: childID, allowPendingRecovery: true)
      guard let taskID = binding.currentTaskID else {
        throw ServiceStoreError.invalidArgument("embedded_dsh.child_task")
      }
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
      return try Self.childState(snapshot, childID: childID)
    case "send":
      return try await sendSubagent(payload, rootID: rootID, childID: childID)
    case "stop":
      let binding = try await child(rootID: rootID, childID: childID)
      if let taskID = binding.currentTaskID {
        try await application.serviceStopTask(
          taskID: taskID.rawValue, deadline: .now.advanced(by: .seconds(40)))
      }
      return .object(["state": .string("interrupted")])
    default: throw ServiceStoreError.invalidArgument("embedded_dsh.subagent_operation")
    }
  }

  private func startSubagent(
    _ payload: [String: ACPJSONValue], rootID: String, childID: String, projectID: ProjectID
  ) async throws -> ACPJSONValue {
    let installationID = try Self.requiredString(payload, "installationID")
    let providerID: String
    if installationID == "codex" {
      providerID = "codex"
    } else {
      let catalog = try await application.serviceAgents(
        projectID: projectID.rawValue, deadline: .now.advanced(by: .seconds(40)))
      guard
        let agent = catalog.agents.first(where: {
          $0.installationID == installationID && $0.enabled && $0.taskSubmissionEnabled
        })
      else { throw ServiceStoreError.invalidArgument("embedded_dsh.installation") }
      providerID = agent.providerID
    }
    return try await submitSubagent(
      payload, rootID: rootID, childID: childID, projectID: projectID,
      providerID: providerID, installationID: installationID == "codex" ? nil : installationID,
      nativeSessionID: nil)
  }

  private func submitSubagent(
    _ payload: [String: ACPJSONValue], rootID: String, childID: String, projectID: ProjectID,
    providerID: String, installationID: String?, nativeSessionID: String?
  ) async throws -> ACPJSONValue {
    let requestID = try Self.requiredString(payload, "requestID")
    let prompt = try Self.requiredString(payload, "prompt")
    guard let execution = try await application.embeddedDSHExecution(sessionID: rootID) else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.execution")
    }
    let submission = MCPServiceTaskSubmission(
      projectID: projectID.rawValue, prompt: prompt, threadID: nativeSessionID,
      providerID: providerID, installationID: installationID,
      executionModel: payload["model"]?.stringValue,
      executionEffort: payload["effort"]?.stringValue,
      modelOverride: payload["model"] != nil,
      permissionMode: execution.permissionMode.rawValue, clientRequestID: requestID,
      queueIfBusy: false)
    let result = try await application.submitEmbeddedDSHSubagent(
      submission, parentSessionID: rootID, childID: childID,
      deadline: .now.advanced(by: .seconds(40)))
    return .object([
      "childID": .string(childID), "taskID": .string(result.taskID),
      "state": .string(result.status), "waitingForApproval": .bool(result.localApprovalRequired),
    ])
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
    if let result = try await previousInputResult(payload, rootID: rootID, childID: childID) {
      return result
    }
    let binding = try await child(rootID: rootID, childID: childID)
    guard let taskID = binding.currentTaskID else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.child_task")
    }
    let snapshot = try await application.serviceTask(
      taskID: taskID.rawValue, recentEventLimit: 1, deadline: .now.advanced(by: .seconds(40)))
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
        nativeSessionID: nativeSessionID)
    }
    return try await steerSubagent(payload, task: snapshot, rootID: rootID, childID: childID)
  }

  private func steerSubagent(
    _ payload: [String: ACPJSONValue], task: MCPServiceTaskSnapshot, rootID: String, childID: String
  ) async throws -> ACPJSONValue {
    let requestID = try Self.requiredString(payload, "requestID")
    let prompt = try Self.requiredString(payload, "prompt")
    let key =
      "embedded_dsh.input." + Self.digest([rootID, childID, requestID].joined(separator: "\0"))
    let fingerprint = Self.digest(prompt)
    guard let turnID = task.turnID ?? task.providerRunID else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.child_not_running")
    }
    try await store.setSetting(
      ServiceSettingRecord(
        key: key, value: Self.json(.object(["fingerprint": .string(fingerprint)])),
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
            "fingerprint": .string(fingerprint), "result": result,
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
    guard previous["fingerprint"]?.stringValue == Self.digest(prompt) else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.input_identity")
    }
    guard let result = previous["result"] else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.input_outcome_unknown")
    }
    return result
  }

  private static func childState(_ task: MCPServiceTaskSnapshot, childID: String) throws
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

  private static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
