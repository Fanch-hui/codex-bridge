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
  var providerName: String? = nil
  /// Reasoning levels the model accepts as `reasoning_effort`, in escalation order; nil when none
  /// are declared and the provider's own default applies.
  var reasoningEfforts: [String]? = nil

  static let reasoningEffortLevels = ["minimal", "low", "medium", "high", "xhigh", "max"]

  /// The standard levels among `declared`, in escalation order; nil when none remain.
  static func reasoningEfforts(_ declared: [String]) -> [String]? {
    let levels = reasoningEffortLevels.filter(Set(declared).contains)
    return levels.isEmpty ? nil : levels
  }

  var presentation: ACPJSONValue {
    var fields: [String: ACPJSONValue] = [
      "id": .string(id), "name": .string(name), "providerID": .string(providerID),
      "source": .string(pluginID == nil ? "built-in" : "community"),
    ]
    if let providerName { fields["providerName"] = .string(providerName) }
    return .object(fields)
  }
}

enum ServiceGatewayRequestError: Error {
  case unsupported(String)
  case unauthorized
}
