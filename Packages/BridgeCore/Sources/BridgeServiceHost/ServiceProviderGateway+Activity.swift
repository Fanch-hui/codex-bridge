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
      .object([
        "id": .string(id), "clientID": .string(request.client.clientID),
        "providerID": .string(model.providerID), "model": .string(model.id),
        "durationMS": .integer(Int64(Date().timeIntervalSince(started) * 1000)),
        "state": .string(state), "date": .string(ISO8601DateFormatter().string(from: started)),
        "usage": usage,
      ]))
  }
}
