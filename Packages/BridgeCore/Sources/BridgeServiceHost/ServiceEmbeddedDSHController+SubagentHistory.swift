import BridgeACP
import BridgeAgentCore
import BridgeCodexRPC
import BridgeDomain
import BridgeIPC
import BridgeMCP
import BridgeServiceApplication
import BridgeServiceCore
import Foundation

extension ServiceEmbeddedDSHController {
  func subagentSnapshot(
    _ payload: [String: ACPJSONValue], rootID: String,
    binding: EmbeddedDSHSubagentBinding, task: MCPServiceTaskSnapshot
  ) async throws -> ACPJSONValue {
    var result = try Self.childState(task, childID: binding.childID).objectValue ?? [:]
    let isCurrent = binding.currentTaskID?.rawValue == task.taskID
    result["providerID"] = .string(binding.providerID)
    result["installationID"] = binding.installationID.map(ACPJSONValue.string) ?? .null
    result["requestID"] = .string(
      payload["requestID"]?.stringValue ?? binding.currentRequestID)
    let runID = task.turnID ?? task.providerRunID
    result["runID"] = runID.map(ACPJSONValue.string) ?? .null
    if let currentStep = task.currentStep { result["currentStep"] = .string(currentStep) }
    result["changedFiles"] = .array(task.changedFiles.map(ACPJSONValue.string))
    let canSteer = isCurrent ? await application.canSteerSubagent(task) : false
    let supportsContinue =
      binding.providerID == serviceCodexProviderID
      || ServiceAgentProviderPolicyRegistry.policy(
        for: AgentProviderID(rawValue: binding.providerID))?.supportsSessionContinuation == true
    let canContinue =
      isCurrent && supportsContinue && task.waitPolicy.terminal
      && binding.nativeSessionID != nil
    let pending =
      isCurrent
      ? await application.pendingCodexApprovals(taskID: TaskID(rawValue: task.taskID)) : []
    result["capabilities"] = .object([
      "canSend": .bool(canSteer || canContinue), "canSteer": .bool(canSteer),
      "canContinue": .bool(canContinue), "supportsContinue": .bool(supportsContinue),
      "canStop": .bool(isCurrent && !task.waitPolicy.terminal && task.status != "unknown"),
      "canAnswer": .bool(!pending.isEmpty),
    ])
    result["waitingForApproval"] = .bool(!pending.isEmpty)
    let history = try await subagentMessages(
      payload, rootID: rootID, binding: binding, task: task)
    result.merge(history) { _, new in new }
    let enriched = try await enrichWorkspaceState(
      .object(result), rootID: rootID, childID: binding.childID,
      taskID: task.taskID, state: task.status)
    var final = enriched.objectValue ?? [:]
    let canRepair = canContinue && final["canRepairWithAgent"]?.boolValue == true
    var capabilities = final["capabilities"]?.objectValue ?? [:]
    capabilities["canRepairWithAgent"] = .bool(canRepair)
    if final["workspaceMode"]?.stringValue == "isolated", canContinue,
      !["merged", "retained"].contains(final["workspaceStatus"]?.stringValue ?? ""), !canRepair
    {
      capabilities["canContinue"] = .bool(false)
      capabilities["canSend"] = .bool(canSteer)
    }
    if final["workspaceMode"]?.stringValue == "isolated",
      binding.providerID == serviceCodexProviderID, !CodexIsolatedLaunch.supportsFileOnlyExecution
    {
      capabilities["canContinue"] = .bool(false)
      capabilities["canRepairWithAgent"] = .bool(false)
      capabilities["canSend"] = .bool(canSteer)
    }
    final["capabilities"] = .object(capabilities)
    return .object(final)
  }

  private func subagentMessages(
    _ payload: [String: ACPJSONValue], rootID: String,
    binding: EmbeddedDSHSubagentBinding, task: MCPServiceTaskSnapshot
  ) async throws -> [String: ACPJSONValue] {
    let limit = min(500, max(1, payload["limit"]?.intValue ?? 200))
    let before = payload["beforeMessageID"]?.intValue.map(Int64.init)
    let records = try await store.embeddedDSHMessages(
      parentSessionID: rootID, childID: binding.childID, beforeMessageID: before,
      limit: limit + 1)
    var liveByKey: [String: IPCTaskConversationMessage] = [:]
    var liveOrder: [String] = []
    if before == nil, binding.currentTaskID?.rawValue == task.taskID {
      let page = try await application.serviceConversationPage(
        taskID: task.taskID, beforeMessageID: nil, limit: 1,
        deadline: .now.advanced(by: .seconds(30)))
      let live = BridgeServiceRequestController.conversationPage(
        taskID: task.taskID, entries: page.liveEntries)
      for message in live.messages {
        if liveByKey[message.key] == nil { liveOrder.append(message.key) }
        liveByKey[message.key] = message
      }
    }
    var messages: [(id: Int64?, value: ACPJSONValue)] = []
    for record in records {
      let stored = record.message
      let live =
        stored.taskID.rawValue == task.taskID ? liveByKey.removeValue(forKey: stored.key) : nil
      let message =
        live
        ?? IPCTaskConversationMessage(
          messageID: stored.id, key: stored.key, role: stored.role.rawValue,
          kind: stored.kind.rawValue, content: stored.content, toolName: stored.toolName,
          toolStatus: stored.toolStatus, toolArguments: stored.toolArguments,
          final: stored.isFinal(for: record.taskStatus))
      var value = try Self.value(message).objectValue ?? [:]
      value["message_id"] = .integer(stored.id)
      value["taskID"] = .string(stored.taskID.rawValue)
      value["requestID"] = .string(record.requestID)
      if let runID = record.runID { value["runID"] = .string(runID) }
      messages.append((stored.id, Self.boundedSubagentMessage(value)))
    }
    for key in liveOrder {
      guard let message = liveByKey[key], message.messageID == nil else { continue }
      var value = try Self.value(message).objectValue ?? [:]
      value["taskID"] = .string(task.taskID)
      value["requestID"] = .string(binding.currentRequestID)
      if let runID = task.turnID ?? task.providerRunID { value["runID"] = .string(runID) }
      messages.append((nil, Self.boundedSubagentMessage(value)))
    }
    if messages.isEmpty, before == nil {
      for (role, content) in [("user", task.prompt), ("agent", task.resultSummary)] {
        guard let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          continue
        }
        messages.append(
          (
            nil,
            Self.boundedSubagentMessage([
              "key": .string("fallback:\(role):\(task.taskID)"), "taskID": .string(task.taskID),
              "requestID": .string(binding.currentRequestID), "role": .string(role),
              "kind": .string(role), "content": .string(content),
              "final": .bool(role == "user" || task.waitPolicy.terminal),
            ])
          ))
      }
    }
    var visible: [(id: Int64?, value: ACPJSONValue)] = []
    var bytes = 0
    for message in messages.reversed() {
      let size = try message.value.encodedData().count
      if visible.count == limit || bytes + size > 1_024 * 1_024 { break }
      visible.append(message)
      bytes += size
    }
    visible.reverse()
    let more = messages.count > visible.count
    let cursor =
      visible.compactMap(\.id).first
      ?? (more ? messages.dropLast(visible.count).compactMap(\.id).last.map { $0 + 1 } : nil)
    return [
      "messages": .array(visible.map(\.value)), "hasMore": .bool(more && cursor != nil),
      "beforeMessageID": cursor.map(ACPJSONValue.integer) ?? .null,
    ]
  }

  private static func boundedSubagentMessage(_ value: [String: ACPJSONValue]) -> ACPJSONValue {
    var result = value
    for key in ["content", "tool_arguments"] {
      if let text = result[key]?.stringValue {
        result[key] = .string(AgentProgressText.bounded(text, maximumBytes: 32 * 1_024))
      }
    }
    return .object(result)
  }
}
