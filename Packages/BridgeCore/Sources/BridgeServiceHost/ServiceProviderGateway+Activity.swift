import BridgeACP
import BridgeModelGateway
import Foundation

extension ServiceProviderGateway {
  func markRunning(_ id: String) {
    guard var entry = activeRequests[id]?.objectValue else { return }
    entry["state"] = .string("running")
    activeRequests[id] = .object(entry)
  }

  func record(
    _ id: String, request: ModelGatewayRequest, model: ServiceGatewayModel,
    started: Date, state: String, usage: ACPJSONValue
  ) async {
    activeRequests.removeValue(forKey: id)
    await appendActivity(
      id: id, clientID: request.client.clientID, providerID: model.providerID, model: model.id,
      started: started, state: state, usage: usage)
  }

  /// Official Codex models are passed through unchanged; only their reported counts are kept.
  func recordOfficialCodex(
    request: ModelGatewayRequest, model: String, started: Date, state: String,
    usage: ACPJSONValue
  ) async {
    await appendActivity(
      id: UUID().uuidString, clientID: request.client.clientID,
      providerID: Self.officialCodexProviderID, model: model, started: started, state: state,
      usage: usage)
  }

  static let officialCodexProviderID = "codex-official"

  private func appendActivity(
    id: String, clientID: String, providerID: String, model: String, started: Date,
    state: String, usage: ACPJSONValue
  ) async {
    await appendActivity(
      .object([
        "id": .string(id), "clientID": .string(clientID), "providerID": .string(providerID),
        "model": .string(model),
        "durationMS": .integer(Int64(Date().timeIntervalSince(started) * 1000)),
        "state": .string(state), "date": .string(ISO8601DateFormatter().string(from: started)),
        "usage": usage,
      ]))
  }
}
