import BridgeAgentCore
import BridgeDomain
import Foundation

/// A Bridge-extension request for project write admission before one writing Pi tool call.
struct PiToolWriteGateRequest: Sendable, Equatable {
  let wireID: String
  let toolCallID: String

  static let prefix = "codex-bridge.pi.write-gate.v1:"
  static let grantedOption = "granted"
}

extension PiToolWriteGateRequest {
  /// Returns nil for UI requests that are not write-gate requests; throws for malformed ones.
  static func parse(_ value: PiJSONValue, nonce: String, taskID: TaskID) throws -> Self? {
    guard value["method"]?.stringValue == "select",
      let title = value["title"]?.stringValue, title.hasPrefix(prefix)
    else { return nil }
    guard let wireID = value["id"]?.stringValue, !wireID.isEmpty, wireID.utf8.count <= 128,
      value["options"]?.arrayValue?.compactMap(\.stringValue) == [grantedOption],
      title.utf8.count <= 4 * 1_024,
      let payload = try? JSONDecoder().decode(
        PiJSONValue.self, from: Data(title.dropFirst(prefix.count).utf8)),
      payload["revision"]?.integerValue == 1, payload["nonce"]?.stringValue == nonce,
      payload["taskID"]?.stringValue == taskID.rawValue,
      let toolCallID = payload["toolCallID"]?.stringValue, !toolCallID.isEmpty,
      toolCallID.utf8.count <= 200, !toolCallID.contains("\0")
    else { throw PiRPCError.invalidRecord }
    return Self(wireID: wireID, toolCallID: toolCallID)
  }
}
