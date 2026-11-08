import BridgeACP
import BridgeCodexService
import BridgeDomain
import BridgeIPC
import BridgeServiceCore
import Foundation

extension ServiceEmbeddedDSHController {
  func subagentHistory(_ payload: [String: ACPJSONValue]) async throws -> ACPJSONValue {
    let rootID = try Self.requiredString(payload, "sessionId")
    let childID = try Self.requiredString(payload, "childId")
    _ = try await project(for: rootID)
    // A delegated child is listed before its task exists while it reserves a workspace or
    // dispatches; report that as pending instead of a failure the card would display.
    let pendingBinding = try await application.embeddedDSHSubagent(
      parentSessionID: rootID, childID: childID)
    if pendingBinding?.currentTaskID == nil {
      return .object(["pending": .bool(true), "messages": .array([]), "hasMore": .bool(false)])
    }
    let taskID = try await presentationTask(payload)
    guard
      let binding = try await application.embeddedDSHSubagent(
        parentSessionID: rootID, childID: childID)
    else { throw ServiceStoreError.invalidArgument("embedded_dsh.child") }
    let task = try await application.serviceTask(
      taskID: taskID.rawValue, recentEventLimit: 6, deadline: .now.advanced(by: .seconds(30)))
    return try await subagentSnapshot(payload, rootID: rootID, binding: binding, task: task)
  }

  func subagentApprovals(_ payload: [String: ACPJSONValue]) async throws -> ACPJSONValue {
    let sessionID = try Self.requiredString(payload, "sessionId")
    _ = try await project(for: sessionID)
    let children = try await application.embeddedDSHSubagents(parentSessionID: sessionID)
    var rows: [ACPJSONValue] = []
    for child in children {
      guard let taskID = child.currentTaskID else { continue }
      let task = try await application.serviceTask(
        taskID: taskID.rawValue, recentEventLimit: 1, deadline: .now.advanced(by: .seconds(30)))
      let native = await application.pendingCodexApprovals(taskID: taskID)
      let approvals = native.map(BridgeServiceRequestController.approvalSummary)
      for approval in approvals {
        var row = try Self.value(approval).objectValue ?? [:]
        row["childId"] = .string(child.childID)
        row["approvalID"] = .string(approval.approvalID)
        row["taskID"] = .string(taskID.rawValue)
        if let runID = task.turnID ?? task.providerRunID { row["runID"] = .string(runID) }
        row["decisionOptions"] = .array(
          (approval.decisionOptions ?? ["allow", "deny"]).map(ACPJSONValue.string))
        rows.append(.object(row))
      }
    }
    return .object(["approvals": .array(rows)])
  }

  func answerSubagent(_ payload: [String: ACPJSONValue]) async throws -> ACPJSONValue {
    let taskID = try await presentationTask(payload)
    let approvalID = try Self.requiredString(payload, "approvalID")
    let decision = try Self.requiredString(payload, "decision")
    let answers: [String: [String]]?
    if let value = payload["answers"] {
      answers = try JSONDecoder().decode([String: [String]].self, from: value.encodedData())
    } else {
      answers = nil
    }
    if decision == "cancel" {
      try await application.resolveUserInput(
        taskID: taskID, inputID: approvalID, answers: nil, cancelled: true)
    } else if approvalID.hasPrefix("bridge-task-start:") {
      guard decision == "allow" || decision == "deny", answers == nil else {
        throw ServiceStoreError.invalidArgument("embedded_dsh.approval")
      }
      try await application.resolveTaskStartApproval(
        taskID: taskID, approvalID: approvalID, approved: decision == "allow",
        deadline: .now.advanced(by: .seconds(40)))
    } else {
      guard let nativeDecision = LocalApprovalDecision(rawValue: decision) else {
        throw ServiceStoreError.invalidArgument("embedded_dsh.approval")
      }
      try await application.resolveCodexApproval(
        taskID: taskID, approvalID: approvalID, decision: nativeDecision, answers: answers)
    }
    return .object(["accepted": .bool(true)])
  }

  private func presentationTask(_ payload: [String: ACPJSONValue]) async throws -> TaskID {
    let sessionID = try Self.requiredString(payload, "sessionId")
    let childID = try Self.requiredString(payload, "childId")
    _ = try await project(for: sessionID)
    guard
      let binding = try await application.embeddedDSHSubagent(
        parentSessionID: sessionID, childID: childID), let taskID = binding.currentTaskID
    else { throw ServiceStoreError.invalidArgument("embedded_dsh.child") }
    if let expectedTaskID = payload["taskID"]?.stringValue, expectedTaskID != taskID.rawValue {
      throw ServiceStoreError.invalidArgument("embedded_dsh.child_task_mismatch")
    }
    if let expectedRunID = payload["runID"]?.stringValue {
      let task = try await application.serviceTask(
        taskID: taskID.rawValue, recentEventLimit: 1, deadline: .now.advanced(by: .seconds(30)))
      guard expectedRunID == (task.turnID ?? task.providerRunID) else {
        throw ServiceStoreError.invalidArgument("embedded_dsh.child_run_mismatch")
      }
    }
    return taskID
  }
}
