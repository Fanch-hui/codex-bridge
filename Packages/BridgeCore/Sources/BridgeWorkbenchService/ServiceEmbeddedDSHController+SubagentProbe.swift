import BridgeACP
import BridgeServiceCore
import Crypto
import Foundation

extension ServiceEmbeddedDSHController {
  private static func revokedSubagentRequestKey(
    rootID: String, childID: String, requestID: String
  ) -> String {
    let input = Data([rootID, childID, requestID].joined(separator: "\0").utf8)
    let digest = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    return "embedded_dsh.subagent.revoked." + digest
  }

  func ensureSubagentRequestAdmitted(
    _ payload: [String: ACPJSONValue], rootID: String, childID: String
  ) async throws {
    let requestID = try Self.requiredString(payload, "requestID")
    let key = Self.revokedSubagentRequestKey(rootID: rootID, childID: childID, requestID: requestID)
    guard try await store.setting(key: key) == nil else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.subagent_request_revoked")
    }
  }

  func probeSubagent(
    _ payload: [String: ACPJSONValue], rootID: String, childID: String
  ) async throws -> ACPJSONValue {
    let requestID = try Self.requiredString(payload, "requestID")
    await inputGate.acquire()
    defer { inputGate.release() }
    try Task.checkCancellation()
    let mode = try await workspaceMode(rootID: rootID, childID: childID)
    if let original = try await store.embeddedDSHInput(
      parentSessionID: rootID, childID: childID, requestID: requestID)
    {
      return Self.subagentProbeResult(Self.subagentProbeState(original.status), mode: mode)
    }
    let child = try await application.embeddedDSHSubagent(
      parentSessionID: rootID, childID: childID)
    let inputKey =
      "embedded_dsh.input."
      + Self.digest([rootID, childID, requestID].joined(separator: "\0"))
    if let saved = try await store.setting(key: inputKey) {
      let previous = try JSONDecoder().decode(ACPJSONValue.self, from: Data(saved.value.utf8))
      let confirmedTaskID = previous["result"]?["taskID"]?.stringValue
      if let taskID = confirmedTaskID ?? previous["taskID"]?.stringValue {
        if previous["deliveryStatus"]?.stringValue == "delivery_unknown" {
          return Self.subagentProbeResult("delivery_unknown", mode: mode, taskID: taskID)
        }
        do {
          let task = try await application.serviceTask(
            taskID: taskID, recentEventLimit: 1, deadline: .now.advanced(by: .seconds(25)))
          if confirmedTaskID == nil {
            guard ServiceTaskStatus(rawValue: task.status)?.isTerminal == true else {
              return Self.subagentProbeResult("unknown", mode: mode, taskID: taskID)
            }
            var pending = previous.objectValue ?? [:]
            pending["deliveryStatus"] = .string("delivery_unknown")
            try await store.setSetting(
              ServiceSettingRecord(
                key: inputKey, value: Self.json(.object(pending)), updatedAt: Date()))
            return Self.subagentProbeResult("delivery_unknown", mode: mode, taskID: taskID)
          }
          return Self.subagentProbeResult(
            Self.subagentProbeState(ServiceTaskStatus(rawValue: task.status)), mode: mode)
        } catch {
          return Self.subagentProbeResult("unknown", mode: mode)
        }
      }
      return Self.subagentProbeResult("unknown", mode: mode)
    }
    if child?.currentRequestID == requestID {
      return Self.subagentProbeResult("unknown", mode: mode)
    }
    // A delayed start or send must observe this tombstone before dispatch.
    let key = Self.revokedSubagentRequestKey(
      rootID: rootID, childID: childID, requestID: requestID)
    try await store.setSetting(ServiceSettingRecord(key: key, value: "revoked", updatedAt: Date()))
    return Self.subagentProbeResult("absent", mode: mode)
  }

  private static func subagentProbeState(_ status: ServiceTaskStatus?) -> String {
    guard let status, status != .unknown else { return "unknown" }
    return status.isTerminal ? "terminal" : "active"
  }

  private static func subagentProbeResult(
    _ state: String, mode: String, taskID: String? = nil
  ) -> ACPJSONValue {
    var result: [String: ACPJSONValue] = [
      "state": .string(state), "workspaceMode": .string(mode),
    ]
    if let taskID { result["taskID"] = .string(taskID) }
    return .object(result)
  }
}
