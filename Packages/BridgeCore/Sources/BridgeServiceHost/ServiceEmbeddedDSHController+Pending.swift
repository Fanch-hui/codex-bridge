import BridgeACP
import BridgeEmbeddedDSH
import BridgeServiceCore
import Crypto
import Foundation

extension ServiceEmbeddedDSHController {
  func persistWorkspaceRequest(_ event: EmbeddedDSHEvent) async throws {
    guard let nativeID = event.sessionID ?? event.payload["sessionId"]?.stringValue,
      let callID = event.payload["toolCallId"]?.stringValue
    else { return }
    let logicalID = nativeLogicalIDs[nativeID] ?? nativeID
    var payload = event.payload.objectValue ?? [:]
    payload["sessionId"] = .string(logicalID)
    try await store.setSetting(
      ServiceSettingRecord(
        key: workspaceRequestKey(logicalID),
        value: Self.json(.object(payload)), updatedAt: Date()))
    try await store.upsertWorkbenchPendingInteraction(
      .init(
        logicalSessionID: logicalID,
        interactionID: callID, nativeSessionID: nativeID, kind: "workspace",
        eventSeq: max(0, event.sequence ?? Int64(eventCursor))))
  }

  func clearWorkspaceRequest(_ id: String) async throws {
    let logicalID = nativeLogicalIDs[id] ?? id
    let pending = try await store.workbenchPendingInteractions(logicalSessionID: logicalID)
    for item in pending where item.kind == "workspace" {
      try await store.removeWorkbenchPendingInteraction(
        logicalSessionID: logicalID,
        interactionID: item.interactionID, throughEventSeq: item.eventSeq)
    }
  }

  func pendingInteractions() async throws -> ACPJSONValue {
    let result = try await invoke(action: "pending.list", payload: .object([:]))
    let pending = try await store.workbenchPendingInteractions(limit: 500)
    var requests: [ACPJSONValue] = []
    var seen = Set<String>()
    for item in result["items"]?.arrayValue ?? [] where item["type"]?.stringValue == "workspace" {
      var value = item["payload"]?.objectValue ?? [:]
      let nativeID = value["sessionId"]?.stringValue ?? item["sessionID"]?.stringValue ?? ""
      let logicalID = nativeLogicalIDs[nativeID] ?? nativeID
      guard !logicalID.isEmpty, seen.insert(logicalID).inserted else { continue }
      value["sessionId"] = .string(logicalID)
      requests.append(.object(value))
    }
    for item in pending
    where item.kind == "workspace" && !seen.contains(item.logicalSessionID) {
      try await clearWorkspaceRequest(item.logicalSessionID)
    }
    var response = result.objectValue ?? [:]
    response["items"] = .array(
      (result["items"]?.arrayValue ?? []).filter { $0["type"]?.stringValue != "workspace" })
    response["workspaceRequests"] = .array(requests)
    return .object(response)
  }

  private func workspaceRequestKey(_ id: String) -> String {
    "workbench.workspaceRequest."
      + SHA256.hash(data: Data(id.utf8))
      .map { String(format: "%02x", $0) }.joined()
  }

  static func validateQueueUpdate(_ payload: [String: ACPJSONValue]) throws {
    guard let change = payload["action"]?.objectValue,
      let kind = change["kind"]?.stringValue, ["edit", "remove", "steer"].contains(kind)
    else { throw ServiceStoreError.invalidArgument("workbench.queue_action") }
    if kind == "edit" {
      guard let content = change["content"]?.arrayValue,
        content.allSatisfy({ $0["type"]?.stringValue == "text" && $0["text"]?.stringValue != nil })
      else { throw ServiceStoreError.invalidArgument("workbench.queue_content") }
    }
  }
}
