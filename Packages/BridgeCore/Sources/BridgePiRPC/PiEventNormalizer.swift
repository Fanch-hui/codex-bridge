import BridgeAgentCore
import Foundation

struct PiEventNormalizer: Sendable {
  private var messageIndex = 0
  private var blockLengths: [String: Int] = [:]
  private var tools: [String: Tool] = [:]
  private(set) var summary = ""
  private(set) var stopReason: String?
  private(set) var failure: String?

  var activeToolCount: Int { tools.count }

  private struct Tool: Sendable {
    let name: String
    let arguments: String?
  }

  mutating func normalize(_ value: PiJSONValue) throws -> [AgentEvent] {
    switch value["type"]?.stringValue {
    case "message_start":
      guard value["message"]?["role"]?.stringValue == "assistant" else { return [] }
      guard messageIndex < Int.max else { throw PiRPCError.invalidRecord }
      messageIndex += 1
      blockLengths.removeAll()
      return []
    case "message_update": return try messageDelta(value)
    case "message_end": return try messageEnd(value)
    case "tool_execution_start": return try toolStart(value)
    case "tool_execution_update": return try toolUpdate(value, final: false)
    case "tool_execution_end": return try toolUpdate(value, final: true)
    default: return []
    }
  }

  private mutating func messageDelta(_ value: PiJSONValue) throws -> [AgentEvent] {
    guard let update = value["assistantMessageEvent"],
      let kind = update["type"]?.stringValue,
      kind == "text_delta" || kind == "thinking_delta",
      let index = update["contentIndex"]?.integerValue, index >= 0, index < 256,
      let delta = update["delta"]?.stringValue
    else { return [] }
    let key = contentKey(index)
    let remaining = 240 * 1_024 - (blockLengths[key] ?? 0)
    guard remaining > 0 else { return [] }
    let content = Self.bounded(delta, bytes: remaining)
    blockLengths[key, default: 0] += content.utf8.count
    return [
      .content(
        try AgentContentUpdate(
          key: key, role: .assistant,
          kind: kind == "thinking_delta" ? .reasoning : .message, mode: .delta,
          content: content, isFinal: false, authoritative: false))
    ]
  }

  private mutating func messageEnd(_ value: PiJSONValue) throws -> [AgentEvent] {
    guard let message = value["message"], message["role"]?.stringValue == "assistant",
      let blocks = message["content"]?.arrayValue, blocks.count <= 256
    else { return [] }
    stopReason = message["stopReason"]?.stringValue
    failure = message["errorMessage"]?.stringValue.map { Self.bounded($0, bytes: 4 * 1_024) }
    var events: [AgentEvent] = []
    var text: [String] = []
    for (index, block) in blocks.enumerated() {
      let reasoning = block["type"]?.stringValue == "thinking"
      guard let content = block[reasoning ? "thinking" : "text"]?.stringValue else { continue }
      let bounded = Self.bounded(content, bytes: 240 * 1_024)
      events.append(
        .content(
          try AgentContentUpdate(
            key: contentKey(index), role: .assistant,
            kind: reasoning ? .reasoning : .message, mode: .full, content: bounded,
            isFinal: true, authoritative: true)))
      if !reasoning { text.append(bounded) }
    }
    summary = Self.bounded(text.joined(separator: "\n"), bytes: 16 * 1_024)
    return events
  }

  private mutating func toolStart(_ value: PiJSONValue) throws -> [AgentEvent] {
    let id = try toolID(value)
    guard tools[id] == nil, tools.count < 128,
      let name = value["toolName"]?.stringValue, !name.isEmpty, name.utf8.count <= 256
    else { throw PiRPCError.invalidRecord }
    let arguments = (try value["args"]?.text()).map { Self.bounded($0, bytes: 60 * 1_024) }
    tools[id] = Tool(name: name, arguments: arguments)
    return [
      .tool(try AgentToolUpdate(key: id, name: name, status: .inProgress, arguments: arguments))
    ]
  }

  private mutating func toolUpdate(_ value: PiJSONValue, final: Bool) throws -> [AgentEvent] {
    let id = try toolID(value)
    guard let tool = tools[id] else { throw PiRPCError.invalidRecord }
    let result = value[final ? "result" : "partialResult"]
    let content = result?["content"]?.arrayValue ?? []
    guard content.count <= 256 else { throw PiRPCError.invalidRecord }
    let output = Self.bounded(
      content.compactMap { $0["text"]?.stringValue }.joined(separator: "\n"),
      bytes: 240 * 1_024)
    let status: AgentToolStatus =
      final
      ? (value["isError"]?.boolValue == true ? .failed : .completed) : .inProgress
    if final { tools.removeValue(forKey: id) }
    let children = try childRuns(result?["details"], toolName: tool.name)
    return [
      .tool(
        try AgentToolUpdate(
          key: id, name: tool.name,
          kind: tool.name == "bridge_subtask" ? "subagent" : nil, status: status,
          arguments: tool.arguments, output: output, childRuns: children))
    ]
  }

  private func childRuns(_ details: PiJSONValue?, toolName: String) throws -> [AgentChildRun] {
    guard toolName == "bridge_subtask" else { return [] }
    guard let value = details?["codexBridgeChildRuns"] else { return [] }
    guard let encoded = try? value.encoded(), encoded.count <= 64 * 1_024,
      let children = try? JSONDecoder().decode([AgentChildRun].self, from: encoded),
      children.count <= 32, Set(children.map(\.id)).count == children.count
    else { throw PiRPCError.invalidRecord }
    return children
  }

  private func toolID(_ value: PiJSONValue) throws -> String {
    guard let id = value["toolCallId"]?.stringValue, !id.isEmpty, id.utf8.count <= 200,
      !id.contains("\0")
    else { throw PiRPCError.invalidRecord }
    return id
  }

  private func contentKey(_ index: Int) -> String { "pi-message-\(messageIndex)-\(index)" }

  static func bounded(_ value: String, bytes: Int) -> String {
    guard value.utf8.count > bytes else { return value }
    let marker = "\n[输出已截断]"
    guard bytes >= marker.utf8.count + 3 else { return "" }
    let prefix = value.utf8.prefix(max(0, bytes - marker.utf8.count - 3))
    return String(decoding: prefix, as: UTF8.self) + marker
  }
}
