import BridgeACP
import BridgeDomain
import BridgeServiceCore
import Foundation

/// Implements the scheduler task and workspace ports through in-process service functions.
/// Nothing here talks to the engine.
extension ServiceEmbeddedDSHController {
  // MARK: - Dispatch

  static func roundPayload(
    _ round: SubagentRound, operation: String, prompt: String, taskID: String? = nil
  ) -> [String: ACPJSONValue] {
    var payload: [String: ACPJSONValue] = [
      "operation": .string(operation), "rootSessionID": .string(round.key.rootID),
      "childID": .string(round.key.childID), "requestID": .string(round.key.requestID),
      "installationID": .string(round.installationID), "prompt": .string(prompt),
    ]
    if let model = round.options.model { payload["model"] = .string(model) }
    if let effort = round.options.effort { payload["effort"] = .string(effort) }
    if !round.options.attachmentPaths.isEmpty {
      payload["attachmentPaths"] = .array(round.options.attachmentPaths.map(ACPJSONValue.string))
    }
    if let access = round.access { payload["access"] = .string(access.rawValue) }
    if let taskID { payload["taskID"] = .string(taskID) }
    return payload
  }

  func roundDispatchFirst(_ round: SubagentRound, prompt: String) async throws
    -> SubagentDispatchReceipt
  {
    let payload = Self.roundPayload(round, operation: "start", prompt: prompt)
    let preparation = await prepareSubagentStart(payload, projectID: round.projectID)
    let value = try await startSubagent(
      payload, rootID: round.key.rootID, childID: round.key.childID,
      projectID: round.projectID, preparation: preparation)
    guard value["childID"]?.stringValue == round.key.childID else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.receipt")
    }
    return try Self.dispatchReceipt(value)
  }

  func roundSend(_ round: SubagentRound, prompt: String, taskID: String? = nil) async throws
    -> SubagentDispatchReceipt
  {
    let payload = Self.roundPayload(round, operation: "send", prompt: prompt, taskID: taskID)
    let value = try await sendSubagentReceipt(
      payload, rootID: round.key.rootID, childID: round.key.childID)
    return try Self.dispatchReceipt(value)
  }

  static func dispatchReceipt(_ value: ACPJSONValue) throws -> SubagentDispatchReceipt {
    guard let taskID = value["taskID"]?.stringValue, !taskID.isEmpty else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.receipt")
    }
    return SubagentDispatchReceipt(
      taskID: taskID, state: value["state"]?.stringValue ?? "",
      workspaceMode: value["workspaceMode"]?.stringValue.flatMap(SubagentWorkspaceMode.init))
  }

  // MARK: - Reading

  /// A snapshot of one task without its message history (see `subagentSnapshot`).
  func roundSnapshot(rootID: String, childID: String, taskID: String) async throws
    -> SubagentTaskSnapshot
  {
    try await roundView(rootID: rootID, childID: childID, taskID: taskID).snapshot
  }

  /// The snapshot with the fields the page lists for the child, as `subagentSnapshot` made them.
  func roundView(rootID: String, childID: String, taskID: String) async throws
    -> SubagentTaskView
  {
    let (value, _) = try await roundSnapshotValue(
      ["rootSessionID": .string(rootID), "childID": .string(childID), "taskID": .string(taskID)],
      rootID: rootID, childID: childID)
    return SubagentTaskView(
      snapshot: Self.taskSnapshot(value, taskID: taskID), fields: value.objectValue ?? [:])
  }

  /// The task of a request that has no recorded task ID, found through its request ID.
  func roundRecoveredSnapshot(_ key: SubagentRoundKey) async throws -> SubagentTaskSnapshot {
    let (value, taskID) = try await roundSnapshotValue(
      [
        "rootSessionID": .string(key.rootID), "childID": .string(key.childID),
        "requestID": .string(key.requestID),
      ], rootID: key.rootID, childID: key.childID)
    return Self.taskSnapshot(value, taskID: taskID)
  }

  private func roundSnapshotValue(
    _ payload: [String: ACPJSONValue], rootID: String, childID: String
  ) async throws -> (value: ACPJSONValue, taskID: String) {
    let binding = try await child(rootID: rootID, childID: childID, allowPendingRecovery: true)
    let taskID = try await selectedSubagentTask(payload, rootID: rootID, binding: binding)
    let task = try await application.serviceTask(
      taskID: taskID.rawValue, recentEventLimit: 1, deadline: .now.advanced(by: .seconds(25)))
    let value = try await subagentSnapshot(
      payload, rootID: rootID, binding: binding, task: task, includingMessages: false)
    return (value, taskID.rawValue)
  }

  static func taskSnapshot(_ value: ACPJSONValue, taskID: String) -> SubagentTaskSnapshot {
    let capabilities = value["capabilities"]
    return SubagentTaskSnapshot(
      taskID: taskID, state: SubagentTaskState(rawValue: value["state"]?.stringValue ?? "unknown"),
      runID: value["runID"]?.stringValue,
      workspaceMode: value["workspaceMode"]?.stringValue.flatMap(SubagentWorkspaceMode.init),
      workspaceStatus: value["workspaceStatus"]?.stringValue.map {
        SubagentWorkspaceStatus(rawValue: $0)
      },
      canSteer: capabilities?["canSteer"]?.boolValue,
      canContinue: capabilities?["canContinue"]?.boolValue,
      supportsContinue: capabilities?["supportsContinue"]?.boolValue,
      canRepairWithAgent: value["canRepairWithAgent"]?.boolValue == true
        || capabilities?["canRepairWithAgent"]?.boolValue == true)
  }

  func roundProbe(_ key: SubagentRoundKey) async throws -> SubagentProbe {
    let value = try await probeSubagent(
      ["requestID": .string(key.requestID)], rootID: key.rootID, childID: key.childID)
    let state: SubagentProbe.State =
      switch value["state"]?.stringValue {
      case "absent": .absent
      case "active": .active
      case "terminal": .terminal
      case "delivery_unknown": .deliveryUnknown
      default: .unknown
      }
    return SubagentProbe(
      state: state,
      workspaceMode: value["workspaceMode"]?.stringValue.flatMap(SubagentWorkspaceMode.init),
      taskID: value["taskID"]?.stringValue)
  }

  /// The task outcome as it is delivered: state, output, error and the workspace fields.
  func roundResult(_ key: SubagentRoundKey, taskID: String) async throws -> SubagentTaskResult {
    let task = try await application.serviceTask(
      taskID: taskID, recentEventLimit: 1, deadline: .now.advanced(by: .seconds(25)))
    let base: ACPJSONValue = .object([
      "output": task.resultSummary.map(ACPJSONValue.string) ?? .null,
      "error": task.failureCode.map(ACPJSONValue.string) ?? .null,
    ])
    let enriched = try await enrichWorkspaceState(
      base, rootID: key.rootID, childID: key.childID, taskID: taskID, state: task.status)
    var fields = enriched.objectValue ?? [:]
    let output = fields.removeValue(forKey: "output")?.stringValue
    let error = fields.removeValue(forKey: "error")?.stringValue
    return SubagentTaskResult(state: task.status, output: output, error: error, workspace: fields)
  }

  func roundIsLegacyChild(rootID: String, childID: String) async throws -> Bool {
    try await application.embeddedDSHSubagent(parentSessionID: rootID, childID: childID) != nil
  }

  // MARK: - Stopping

  /// Tells the task of a round to stop. A task that already finished needs nothing, and a round
  /// whose task is not known yet is looked up through its request.
  func roundStop(_ key: SubagentRoundKey, taskID: String?) async throws {
    let input = try await store.embeddedDSHInput(
      parentSessionID: key.rootID, childID: key.childID, requestID: key.requestID)
    guard let id = taskID ?? input?.taskID?.rawValue else { return }
    let binding = try await child(
      rootID: key.rootID, childID: key.childID, allowPendingRecovery: true)
    let selected = try await selectedSubagentTask(
      ["taskID": .string(id)], rootID: key.rootID, binding: binding)
    let task = try await application.serviceTask(
      taskID: selected.rawValue, recentEventLimit: 1, deadline: .now.advanced(by: .seconds(40)))
    guard !task.waitPolicy.terminal else { return }
    try await application.serviceStopTask(
      taskID: selected.rawValue, deadline: .now.advanced(by: .seconds(40)))
  }

  // MARK: - Workspace

  func roundRootIsReadOnly(rootID: String) async throws -> Bool {
    try await activeSubagentExecution(rootID: rootID).permissionMode != .full
  }

  func projectRuntimeOwners(_ projectID: ProjectID) async throws -> [String] {
    var owners: [String] = []
    for execution in try await application.embeddedDSHExecutions()
    where execution.projectID == projectID {
      for child in try await application.embeddedDSHSubagents(parentSessionID: execution.sessionID)
      where child.currentTaskID != nil && child.currentStatus?.isTerminal != true {
        owners.append(
          Self.roundExecutionOwner(
            .init(
              rootID: execution.sessionID, childID: child.childID, requestID: child.currentRequestID
            )))
      }
    }
    return owners
  }

  static func roundExecutionOwner(_ key: SubagentRoundKey) -> String {
    "external:" + digest([key.rootID, key.childID, key.requestID].joined(separator: "\0"))
  }

  func reserveRoundExecution(_ round: SubagentRound) async throws -> Bool {
    let capacity = try await settings.projectWriteConcurrencySnapshot()
    let result = try await invoke(
      action: "runtime.reserve",
      payload: .object([
        "projectID": .string(round.projectID.rawValue),
        "owner": .string(Self.roundExecutionOwner(round.key)),
        "limit": .integer(Int64(capacity.limit)), "revision": .number(capacity.revision),
      ]))
    return result["state"]?.stringValue == "reserved"
  }

  func roundReserve(_ round: SubagentRound) async throws -> SubagentReservation {
    let value = try await reserveSubagentWorkspace(
      rootID: round.key.rootID, childID: round.key.childID, requestID: round.key.requestID,
      projectID: round.projectID, installationID: round.installationID)
    switch value["state"]?.stringValue {
    case "reserved":
      let scope = value["writeScope"]?.stringValue ?? SubagentWriteScope.task.rawValue
      guard let writeScope = SubagentWriteScope(rawValue: scope) else {
        throw ServiceStoreError.invalidArgument("embedded_dsh.write_scope")
      }
      return .reserved(writeScope)
    case "waiting":
      return .waiting
    default:
      throw ServiceStoreError.invalidArgument("embedded_dsh.reservation")
    }
  }

  func roundReleaseReservation(_ key: SubagentRoundKey) async throws -> SubagentReservationRelease {
    let projectID = try await project(for: key.rootID).id
    let value = try await releaseSubagentWorkspaceReservation(
      rootID: key.rootID, childID: key.childID, requestID: key.requestID, projectID: projectID)
    switch value["state"]?.stringValue {
    case "released":
      _ = try await invoke(
        action: "runtime.release",
        payload: .object([
          "projectID": .string(projectID.rawValue),
          "owner": .string(Self.roundExecutionOwner(key)),
        ]))
      return .released
    case "active", "unknown": return .stillHeld
    default: throw ServiceStoreError.invalidArgument("embedded_dsh.reservation")
    }
  }
}
