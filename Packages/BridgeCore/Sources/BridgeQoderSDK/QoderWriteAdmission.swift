import BridgeACP
import BridgeAgentCore
import Foundation

/// Answers the host's `qoder/workspaceWrite` requests from the task's write gate: the host asks
/// before a writing tool runs and releases afterwards.
struct QoderWriteAdmission: Sendable {
  let admission: AgentToolWriteAdmission
  let client: QoderSDKClient

  init(gate: AgentToolWriteGate, client: QoderSDKClient) {
    admission = AgentToolWriteAdmission(gate: gate)
    self.client = client
  }

  func handle(_ wireID: ACPRequestID, _ value: QoderJSONValue) async throws {
    guard let phase = value["phase"]?.stringValue,
      let toolUseID = value["toolUseID"]?.stringValue,
      !toolUseID.isEmpty, toolUseID.utf8.count <= 200
    else { throw ACPError.invalidMessage }
    switch phase {
    case "acquire":
      try await admission.acquire(toolUseID) { granted in
        await self.reply(wireID, "granted", granted)
      }
    case "release":
      await admission.release(toolUseID)
      await reply(wireID, "released", true)
    default:
      throw ACPError.invalidMessage
    }
  }

  func close(releasingHeld: Bool) async {
    await admission.close(releasingHeld: releasingHeld)
  }

  /// A failed reply has already shut the client down, which ends the execution through its
  /// event stream, and a reply to a request the host withdrew is ignored by the host.
  private func reply(_ wireID: ACPRequestID, _ field: String, _ value: Bool) async {
    try? await client.resolveWorkspaceWrite(wireID, result: .object([field: .bool(value)]))
  }
}
