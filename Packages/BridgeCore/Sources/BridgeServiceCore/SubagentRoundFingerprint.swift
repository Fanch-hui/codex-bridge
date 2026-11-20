import Crypto
import Foundation

/// Request fingerprints and delivery IDs. They are the SHA-256 of the exact bytes
/// `JSON.stringify` produced in the Node orchestrator, so a request recorded there is recognised
/// when it is retried here, and results delivered there are not delivered twice. The key names
/// (`rootSessionID`, ...) are therefore part of the format and must not be renamed.
public enum SubagentRoundFingerprint {
  /// Node `requestHash` of a delegation.
  public static func start(
    rootID: String, childID: String, installationID: String, requestID: String,
    options: SubagentRoundOptions, access: SubagentRoundAccess?, prompt: String,
    dependencies: [SubagentRoundDependency]
  ) -> String {
    var call = [
      member("rootSessionID", rootID), member("childID", childID),
      member("installationID", installationID), member("requestID", requestID),
    ]
    if let model = options.model, !model.isEmpty { call.append(member("model", model)) }
    if let effort = options.effort, !effort.isEmpty { call.append(member("effort", effort)) }
    if !options.attachmentPaths.isEmpty {
      call.append("\"attachmentPaths\":" + stringArray(options.attachmentPaths))
    }
    if let access { call.append(member("access", access.rawValue)) }
    let dependencyList = dependencies.map {
      "{"
        + [member("childID", $0.childID), member("requestID", $0.requestID)].joined(separator: ",")
        + "}"
    }
    let json =
      "{\"call\":{" + call.joined(separator: ",") + "},\"prompt\":" + quote(prompt)
      + ",\"dependencies\":[" + dependencyList.joined(separator: ",") + "]}"
    return hash(json)
  }

  /// Node `promptHash` of a continuation or steer. `delivery` is the mode as requested, before
  /// `auto` is resolved.
  public static func send(
    prompt: String, attachmentPaths: [String], delivery: SubagentDelivery, repairConflict: Bool,
    expectedTaskID: String?, expectedRunID: String?
  ) -> String {
    var members = [
      member("prompt", prompt), "\"attachmentPaths\":" + stringArray(attachmentPaths),
      member("delivery", delivery.rawValue), "\"repairConflict\":\(repairConflict)",
    ]
    if let expectedTaskID { members.append(member("expectedTaskID", expectedTaskID)) }
    if let expectedRunID { members.append(member("expectedRunID", expectedRunID)) }
    return hash("{" + members.joined(separator: ",") + "}")
  }

  /// The fingerprint continuations had before attachments existed: the hash of the bare prompt.
  public static func legacySend(prompt: String) -> String { hash(prompt) }

  /// Node `deliveryID`: names the notice that carries one round's result in the controller's
  /// history, so a repeated delivery can be recognised.
  public static func deliveryID(key: SubagentRoundKey, taskID: String?) -> String {
    let parts = [
      quote(key.rootID), quote(key.childID), quote(key.requestID), taskID.map(quote) ?? "null",
    ]
    return "bridge-" + hash("[" + parts.joined(separator: ",") + "]")
  }

  private static func member(_ name: String, _ value: String) -> String {
    quote(name) + ":" + quote(value)
  }

  private static func stringArray(_ values: [String]) -> String {
    "[" + values.map(quote).joined(separator: ",") + "]"
  }

  private static func hash(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// `JSON.stringify` for a string: escapes quote, backslash and control characters only.
  static func quote(_ text: String) -> String {
    var result = "\""
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 0x22: result += "\\\""
      case 0x5C: result += "\\\\"
      case 0x08: result += "\\b"
      case 0x09: result += "\\t"
      case 0x0A: result += "\\n"
      case 0x0C: result += "\\f"
      case 0x0D: result += "\\r"
      case 0..<0x20: result += String(format: "\\u%04x", scalar.value)
      default: result.unicodeScalars.append(scalar)
      }
    }
    return result + "\""
  }
}
