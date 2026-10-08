import BridgeACP
import BridgeAgentCore
import Foundation

struct DeepSeekHarnessDesktopEventNormalizer: Sendable {
  let request: AgentExecutionRequest
  let binding: AgentBinding
  private var messages: [String: String] = [:]
  private var messageOrder: [String] = []
  private var interactions: Set<String> = []
  private var questionDefinitions: [String: [ACPJSONValue]] = [:]

  init(request: AgentExecutionRequest, binding: AgentBinding) {
    self.request = request
    self.binding = binding
  }

  var summary: String { messageOrder.compactMap { messages[$0] }.joined(separator: "\n\n") }

  func answer(inputID: String, response: AgentUserInputResponse) throws -> ACPJSONValue {
    guard let questions = questionDefinitions[inputID] else {
      throw AgentRuntimeError.approvalUnavailable(inputID)
    }
    guard case .answers(let values) = response else { return .object(["answers": .array([])]) }
    let answers = questions.enumerated().compactMap { index, question -> ACPJSONValue? in
      let id = question["id"]?.stringValue ?? String(index)
      guard let selected = values[id] else { return nil }
      let options = question["options"]?.arrayValue ?? []
      var identifiers: [ACPJSONValue] = []
      var custom: [String] = []
      for value in selected {
        if let option = options.first(where: {
          ($0["label"]?.stringValue ?? $0.stringValue) == value
        }) {
          identifiers.append(.string(option["label"]?.stringValue ?? value))
        } else {
          custom.append(value)
        }
      }
      var fields: [String: ACPJSONValue] = ["id": .string(id), "selected": .array(identifiers)]
      if !custom.isEmpty { fields["custom"] = .string(custom.joined(separator: "\n")) }
      return .object(fields)
    }
    return .object(["answers": .array(answers)])
  }

  mutating func normalize(_ event: ACPJSONValue) throws -> AgentEvent? {
    guard let type = event["eventType"]?.stringValue, let data = event["data"] else {
      throw AgentRuntimeError.malformedEvent("dsh_desktop_event")
    }
    let cursor = event["cursor"]?.intValue ?? 0
    switch type {
    case "message":
      guard data["role"]?.stringValue == "assistant", let content = data["content"]?.stringValue
      else { return nil }
      let key = data["messageID"]?.stringValue ?? "message-\(cursor)"
      if messages[key] == nil { messageOrder.append(key) }
      messages[key] = AgentProgressText.bounded(
        content, maximumBytes: AgentProgressText.maximumContentBytes)
      return .content(
        try AgentContentUpdate(
          key: key, role: .assistant, kind: .message,
          mode: .full, content: content, isFinal: true, authoritative: true))
    case "reasoning":
      guard let content = data["content"]?.stringValue else { return nil }
      return .content(
        try AgentContentUpdate(
          key: data["messageID"]?.stringValue ?? "reasoning-\(cursor)",
          role: .assistant, kind: .reasoning, mode: .full, content: content, isFinal: true))
    case "tool": return try tool(data, cursor: cursor)
    case "usage":
      return .usageStatistics(
        try AgentUsageStatistics(
          inputTokens: data["inputTokens"]?.intValue, outputTokens: data["outputTokens"]?.intValue))
    case "approval": return try approval(data)
    case "question": return try question(data)
    case "completed":
      return .completed(summary: summary, stopReason: data["reason"]?.stringValue ?? "completed")
    case "failed":
      return .failed(
        code: data["code"]?.stringValue ?? "desktop_run_failed",
        summary: data["message"]?.stringValue ?? "DSH 原生任务执行失败。")
    case "cancelled": return .interrupted
    default: return nil
    }
  }

  private func tool(_ data: ACPJSONValue, cursor: Int) throws -> AgentEvent {
    let status: AgentToolStatus
    switch data["status"]?.stringValue {
    case "completed": status = .completed
    case "failed": status = .failed
    case "cancelled": status = .cancelled
    case "pending": status = .pending
    default: status = .inProgress
    }
    return .tool(
      try AgentToolUpdate(
        key: data["toolCallID"]?.stringValue ?? "tool-\(cursor)",
        name: data["name"]?.stringValue ?? "tool", status: status,
        arguments: serialized(data["arguments"]), output: serialized(data["result"])))
  }

  private mutating func approval(_ data: ACPJSONValue) throws -> AgentEvent? {
    guard let id = data["interactionID"]?.stringValue, interactions.insert(id).inserted else {
      return nil
    }
    return .approvalRequested(
      try AgentApprovalRequest(
        approvalID: id, taskID: request.taskID,
        binding: binding, providerItemID: id, kind: .tool,
        title: data["reason"]?.stringValue ?? data["toolName"]?.stringValue ?? "DSH 工具审批",
        options: [
          try AgentApprovalOption(id: "allow_once", name: "允许一次", kind: "allow_once"),
          try AgentApprovalOption(id: "reject_once", name: "拒绝", kind: "reject_once"),
        ]))
  }

  private mutating func question(_ data: ACPJSONValue) throws -> AgentEvent? {
    guard let id = data["interactionID"]?.stringValue, interactions.insert(id).inserted,
      let items = data["questions"]?.arrayValue
    else { return nil }
    questionDefinitions[id] = items
    let questions = try items.enumerated().map { index, item in
      let options = try (item["options"]?.arrayValue ?? []).map { option in
        try AgentUserInputOption(
          label: option["label"]?.stringValue ?? option.stringValue ?? "选项",
          description: option["description"]?.stringValue ?? "")
      }
      return try AgentUserInputQuestion(
        id: item["id"]?.stringValue ?? String(index),
        header: item["header"]?.stringValue ?? "补充信息",
        question: item["question"]?.stringValue ?? item["text"]?.stringValue ?? "请补充信息",
        kind: options.isEmpty ? .input : .select, options: options,
        allowsMultiple: !options.isEmpty && item["multiSelect"]?.boolValue == true,
        allowsCustomText: true)
    }
    return .userInputRequested(
      try AgentUserInputRequest(
        inputID: id, taskID: request.taskID,
        binding: binding, providerItemID: id, title: "DSH 需要补充信息", summary: "请回答原生任务的问题。",
        questions: questions))
  }

  private func serialized(_ value: ACPJSONValue?) -> String? {
    guard let value, value != .null else { return nil }
    return value.stringValue ?? value.encodedString()
  }
}
