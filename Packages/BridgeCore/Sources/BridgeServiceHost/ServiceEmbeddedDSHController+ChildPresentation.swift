import BridgeACP
import BridgeCodexService
import BridgeDomain
import BridgeIPC
import BridgeServiceCore
import Foundation

extension ServiceEmbeddedDSHController {
  func subagentHistory(_ payload: [String: ACPJSONValue]) async throws -> ACPJSONValue {
    let taskID = try await presentationTask(payload)
    let limit = min(500, max(1, payload["limit"]?.intValue ?? 200))
    let page = try await application.serviceConversationPage(
      taskID: taskID.rawValue,
      beforeMessageID: payload["beforeMessageID"]?.intValue.map(Int64.init),
      limit: limit, deadline: .now.advanced(by: .seconds(30)))
    let livePage = BridgeServiceRequestController.conversationPage(
      taskID: taskID.rawValue, entries: page.liveEntries)
    let liveKeys = Set(livePage.messages.map(\.key))
    let persisted = page.messages.filter { !liveKeys.contains($0.key) }.map { message in
      IPCTaskConversationMessage(
        messageID: message.id, key: message.key, role: message.role.rawValue,
        kind: message.kind.rawValue, content: message.content, toolName: message.toolName,
        toolStatus: message.toolStatus, toolArguments: message.toolArguments,
        final: message.isFinal(for: page.taskStatus))
    }
    return .object([
      "taskID": .string(taskID.rawValue), "state": .string(page.taskStatus.rawValue),
      "messages": try Self.value(Array((persisted + livePage.messages).suffix(limit))),
      "beforeMessageID": page.messages.first.map { .integer($0.id) } ?? .null,
    ])
  }

  func subagentApprovals(_ payload: [String: ACPJSONValue]) async throws -> ACPJSONValue {
    let sessionID = try Self.requiredString(payload, "sessionId")
    _ = try await project(for: sessionID)
    let children = try await application.embeddedDSHSubagents(parentSessionID: sessionID)
    var rows: [ACPJSONValue] = []
    for child in children {
      guard let taskID = child.currentTaskID else { continue }
      let starts = try await application.pendingTaskStartApprovals(taskID: taskID)
      let native = await application.pendingCodexApprovals(taskID: taskID)
      let approvals =
        starts.map(BridgeServiceRequestController.taskStartApprovalSummary)
        + native.map(BridgeServiceRequestController.approvalSummary)
      for approval in approvals {
        var row = try Self.value(approval).objectValue ?? [:]
        row["childId"] = .string(child.childID)
        row["approvalID"] = .string(approval.approvalID)
        row["taskID"] = .string(taskID.rawValue)
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
    return taskID
  }
}
