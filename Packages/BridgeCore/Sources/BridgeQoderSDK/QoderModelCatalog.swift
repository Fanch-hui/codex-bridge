import BridgeACP
import BridgeAgentCore
import Foundation

public enum QoderModelCatalog {
  public static func parse(_ value: QoderJSONValue) throws -> [AgentModelDescriptor] {
    guard let models = value.arrayValue, models.count <= 4096 else { throw ACPError.invalidMessage }
    let result = try models.map { item -> AgentModelDescriptor in
      guard let id = item["id"]?.stringValue, let name = item["name"]?.stringValue,
        let raw = item["efforts"]?.arrayValue, raw.count <= 64,
        let known = item["effortsKnown"]?.boolValue
      else { throw ACPError.invalidMessage }
      let efforts = raw.compactMap(\.stringValue)
      guard efforts.count == raw.count else { throw ACPError.invalidMessage }
      let rawModalities = item["inputModalities"]?.arrayValue
      let modalities = try rawModalities.map { values -> [AgentInputModality] in
        let parsed = values.compactMap {
          $0.stringValue.flatMap(AgentInputModality.init(rawValue:))
        }
        guard parsed.count == values.count else { throw ACPError.invalidMessage }
        return parsed
      }
      return try AgentModelDescriptor(
        id: id, displayName: name, supportedReasoningEfforts: efforts,
        defaultReasoningEffort: item["defaultEffort"]?.stringValue,
        reasoningCapabilitiesAvailable: known, isDefaultModel: item["isDefaultModel"]?.boolValue,
        contextWindowTokens: item["contextWindow"]?.intValue, inputModalities: modalities)
    }
    guard Set(result.map(\.id)).count == result.count else { throw ACPError.invalidMessage }
    return result
  }
}
