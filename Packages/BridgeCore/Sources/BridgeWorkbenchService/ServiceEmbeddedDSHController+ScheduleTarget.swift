import BridgeACP
import BridgeServiceCore
import Crypto
import Foundation

extension ServiceEmbeddedDSHController {
  func frozenScheduleTarget(
    _ action: String, input: [String: ACPJSONValue],
    resolved: [String: ACPJSONValue]
  ) async throws -> [String: ACPJSONValue] {
    guard let logicalID = input["sessionId"]?.stringValue,
      let requestID = input["requestId"]?.stringValue
    else { return resolved }
    let digest = SHA256.hash(data: Data((logicalID + "\0" + requestID).utf8))
      .map { String(format: "%02x", $0) }.joined()
    let key = "workbench.scheduleRequest." + digest
    var payload = resolved
    if let saved = try await store.setting(key: key) {
      let record = try Self.decodeObject(saved.value)
      if action != "schedule.createStatus", let request = record["request"],
        Self.canonicalJSON(request) != Self.canonicalJSON(.object(input))
      {
        throw ServiceStoreError.invalidArgument("workbench.schedule_request_conflict")
      }
      if let nativeID = record["nativeSessionID"]?.stringValue {
        try await authorizeSession(nativeID, requiresProject: false)
        payload["sessionId"] = .string(nativeID)
      }
      return payload
    }
    if action == "schedule.createStatus" { return payload }
    guard let nativeID = resolved["sessionId"]?.stringValue else {
      throw ServiceStoreError.invalidArgument("workbench.schedule_session")
    }
    try await store.setSetting(
      .init(
        key: key,
        value: Self.json(
          .object([
            "nativeSessionID": .string(nativeID), "request": .object(input),
          ])), updatedAt: Date()))
    return payload
  }
}
