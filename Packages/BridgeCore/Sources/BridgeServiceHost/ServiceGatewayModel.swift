import BridgeACP
import Foundation

struct ServiceGatewayModel: Codable, Sendable, Equatable {
  let id: String
  let name: String
  let providerID: String
  let modelID: String
  let pluginID: String?
  let protocolName: String
  let account: String?
  var maximumConcurrency: Int? = nil
  var contextWindow: Int? = nil
  var defaultMaxTokens: Int? = nil
  var supportsImages: Bool? = nil
  var supportsSampling: Bool? = nil

  var presentation: ACPJSONValue {
    .object([
      "id": .string(id), "name": .string(name), "providerID": .string(providerID),
      "source": .string(pluginID == nil ? "built-in" : "community"),
    ])
  }
}

enum ServiceGatewayRequestError: Error {
  case unsupported(String)
  case unauthorized
}
