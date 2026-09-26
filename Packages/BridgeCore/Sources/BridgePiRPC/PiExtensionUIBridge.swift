import BridgeAgentCore
import BridgeDomain
import Foundation

struct PiExtensionApproval: Sendable {
  let request: AgentApprovalRequest
  let wireID: String
  let wireOptions: [String: String]
}

enum PiExtensionUIBridge {
  static let prefix = "codex-bridge.pi.approval.v1:"

  static func approval(
    _ value: PiJSONValue, nonce: String, taskID: TaskID, binding: AgentBinding
  ) throws -> PiExtensionApproval? {
    guard value["method"]?.stringValue == "select",
      let title = value["title"]?.stringValue, title.hasPrefix(prefix)
    else { return nil }
    guard let id = value["id"]?.stringValue, !id.isEmpty, id.utf8.count <= 128,
      let rawOptions = value["options"]?.arrayValue, rawOptions.count == 3,
      let options = value["options"]?.arrayValue?.compactMap(\.stringValue),
      options == ["allow_once", "allow_for_session", "deny"], title.utf8.count <= 16 * 1_024,
      let payload = try? JSONDecoder().decode(
        PiJSONValue.self, from: Data(title.dropFirst(prefix.count).utf8)),
      payload["revision"]?.integerValue == 1, payload["nonce"]?.stringValue == nonce,
      payload["taskID"]?.stringValue == taskID.rawValue,
      let tool = payload["tool"]?.stringValue, let callID = payload["toolCallID"]?.stringValue,
      let digest = payload["payloadDigest"]?.stringValue, digest.utf8.count == 64,
      digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
      let paths = payload["relativePaths"]?.arrayValue, paths.count <= 1
    else { throw PiRPCError.invalidRecord }
    let relativePaths = paths.compactMap(\.stringValue)
    guard relativePaths.count == paths.count else { throw PiRPCError.invalidRecord }
    let command = payload["command"]?.stringValue
    let approvalKind: AgentApprovalKind
    let networkTarget: String?
    switch payload["approvalKind"]?.stringValue {
    case "network":
      guard let target = payload["networkTarget"]?.stringValue, !target.isEmpty,
        target.utf8.count <= 1_024, command == nil, relativePaths.isEmpty
      else { throw PiRPCError.invalidRecord }
      approvalKind = .network
      networkTarget = target
    case "tool":
      guard command == nil, relativePaths.isEmpty else { throw PiRPCError.invalidRecord }
      approvalKind = .tool
      networkTarget = nil
    case "command":
      guard command != nil else { throw PiRPCError.invalidRecord }
      approvalKind = .command
      networkTarget = nil
    case "file_change":
      guard command == nil else { throw PiRPCError.invalidRecord }
      approvalKind = .fileChange
      networkTarget = nil
    default:
      approvalKind = command == nil ? .fileChange : .command
      networkTarget = nil
    }
    let request = try AgentApprovalRequest(
      approvalID: "pi-" + UUID().uuidString.lowercased(), taskID: taskID, binding: binding,
      providerItemID: callID, kind: approvalKind, title: "Pi 请求执行 \(tool)",
      normalizedPayloadDigest: digest, relativePaths: relativePaths, normalizedCommand: command,
      networkTarget: networkTarget,
      options: [
        AgentApprovalOption(id: "allow_once", name: "仅本次允许", kind: "allow_once"),
        AgentApprovalOption(id: "allow_for_session", name: "本次运行允许相同操作", kind: "allow_for_session"),
        AgentApprovalOption(id: "deny", name: "拒绝", kind: "reject_once"),
      ])
    return PiExtensionApproval(
      request: request, wireID: id,
      wireOptions: Dictionary(uniqueKeysWithValues: options.map { ($0, $0) }))
  }
}
