import BridgeAgentCore
import BridgeDomain
import Foundation

enum PiExtensionPlanBridge {
  static let statusKey = "codex-bridge.pi.plan"

  static func plan(
    _ value: PiJSONValue,
    nonce: String,
    taskID: TaskID
  ) throws -> [AgentPlanEntry]? {
    guard value["type"]?.stringValue == "extension_ui_request",
      value["method"]?.stringValue == "setStatus",
      value["statusKey"]?.stringValue == statusKey
    else { return nil }
    guard let text = value["statusText"]?.stringValue,
      text.utf8.count <= 64 * 1_024,
      let payload = try? JSONDecoder().decode(PiJSONValue.self, from: Data(text.utf8)),
      payload["revision"]?.integerValue == 1,
      payload["nonce"]?.stringValue == nonce,
      payload["taskID"]?.stringValue == taskID.rawValue,
      let items = payload["items"]?.arrayValue, items.count <= 64
    else { throw PiRPCError.invalidRecord }

    var identifiers = Set<String>()
    return try items.map { item in
      guard let id = item["id"]?.stringValue, !id.isEmpty,
        id.utf8.count <= 128, !id.contains("\0"), identifiers.insert(id).inserted,
        let content = item["content"]?.stringValue,
        let priority = item["priority"]?.stringValue,
        ["low", "normal", "high"].contains(priority),
        let status = item["status"]?.stringValue,
        ["pending", "in_progress", "completed"].contains(status)
      else { throw PiRPCError.invalidRecord }
      return try AgentPlanEntry(content: content, priority: priority, status: status)
    }
  }
}
