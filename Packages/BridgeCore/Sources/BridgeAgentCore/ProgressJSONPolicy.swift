import Foundation

struct ProgressJSONPolicy: Sendable {
  let dialect: ProgressJSONLineDecoder.Dialect
  private static let marker = "[进度内容过长，已省略展示]"

  func isPresentationPath(_ path: String) -> Bool {
    switch dialect {
    case .codex:
      return codexPaths.contains(path)
    case .acp:
      return ["params.update.content", "params.update.rawOutput", "params.update.rawInput"]
        .contains(path)
    case .pi:
      return [
        "args", "result.content", "partialResult.content", "message.content",
        "assistantMessageEvent.delta", "assistantMessageEvent.message.content",
        "message.errorMessage",
      ].contains(path)
    case .antigravity:
      return ["step_update.text_delta", "result.response"].contains(path)
        || path.hasPrefix("step_update.tool_info.")
          && ["input", "output", "arguments", "parameters", "result", "content"].contains(
            String(path.split(separator: ".").last ?? ""))
    }
  }

  func allowsOmissions(_ object: [String: Any], paths: Set<String>) -> Bool {
    guard paths.allSatisfy(isPresentationPath) else { return false }
    switch dialect {
    case .codex:
      guard object["id"] == nil, let method = object["method"] as? String else { return false }
      return [
        "item/started", "item/completed", "item/agentMessage/delta", "item/reasoning/textDelta",
        "item/reasoning/summaryTextDelta", "item/commandExecution/outputDelta",
        "item/fileChange/outputDelta", "turn/plan/updated", "turn/diff/updated",
      ].contains(method)
    case .acp:
      guard object["id"] == nil, object["method"] as? String == "session/update",
        let params = object["params"] as? [String: Any],
        let update = params["update"] as? [String: Any],
        let kind = update["sessionUpdate"] as? String
      else { return false }
      return [
        "agent_message_chunk", "agent_thought_chunk", "user_message_chunk", "tool_call",
        "tool_call_update",
      ].contains(kind)
    case .pi:
      guard let kind = object["type"] as? String else { return false }
      return [
        "message_start", "message_update", "message_end", "tool_execution_start",
        "tool_execution_update", "tool_execution_end",
      ].contains(kind)
    case .antigravity:
      return ["step_update", "result"].contains(object["event"] as? String ?? "")
    }
  }

  func replacement(path: String, first: UInt8) -> Data {
    if path == "params.update.rawInput" {
      return encoded(["_bridgeDisplayOmitted": true, "display": Self.marker])
    }
    if first == 0x22 { return encoded(Self.marker) }
    switch dialect {
    case .acp where path == "params.update.content":
      let content: [String: Any] = ["type": "text", "text": Self.marker]
      return first == 0x5B
        ? encoded([["type": "content", "content": content]]) : encoded(content)
    case .pi where path.hasSuffix(".content"):
      return encoded([["type": "text", "text": Self.marker]])
    default:
      return first == 0x5B
        ? encoded([Self.marker])
        : encoded(["_bridgeDisplayOmitted": true, "display": Self.marker])
    }
  }

  private func encoded(_ value: Any) -> Data {
    // Every replacement is generated from fixed values, never from partial JSON.
    (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data()
  }

  private var codexPaths: Set<String> {
    [
      "params.delta", "params.text", "params.output", "params.diff", "params.explanation",
      "params.plan.*.step", "params.item.aggregatedOutput", "params.item.text",
      "params.item.content", "params.item.changes.*.diff",
      "params.item.command", "params.item.commandActions.*.command",
      "params.item.commandActions.*.name", "params.item.commandActions.*.query",
    ]
  }
}
