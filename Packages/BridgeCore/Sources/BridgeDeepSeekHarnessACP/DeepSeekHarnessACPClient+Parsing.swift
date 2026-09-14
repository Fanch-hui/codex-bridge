import BridgeACP
import BridgeAgentCore
import Foundation

extension DeepSeekHarnessACPClient {
  static func parseConfigOptions(_ value: ACPJSONValue?) throws
    -> [DeepSeekHarnessACPConfigOption]
  {
    guard let value else { return [] }
    guard let rawOptions = value.arrayValue, rawOptions.count <= 64 else {
      throw DeepSeekHarnessACPError.malformedResponse
    }
    var seen = Set<String>()
    return try rawOptions.map { raw in
      guard let object = raw.objectValue,
        let id = object["id"]?.stringValue,
        seen.insert(id).inserted
      else {
        throw DeepSeekHarnessACPError.malformedResponse
      }
      try validateConfigText(id, maximumBytes: 256)
      let category = object["category"]?.stringValue
      if let category { try validateConfigText(category, maximumBytes: 64) }
      let currentValue = object["currentValue"]?.stringValue
      if let currentValue { try validateConfigValue(currentValue, maximumBytes: 256) }
      guard let rawValues = object["options"]?.arrayValue, rawValues.count <= 512 else {
        throw DeepSeekHarnessACPError.malformedResponse
      }
      var seenValues = Set<String>()
      let values = try parseConfigValues(
        rawValues,
        seenValues: &seenValues,
        depth: 0
      )
      return DeepSeekHarnessACPConfigOption(
        id: id,
        category: category,
        currentValue: currentValue,
        values: values
      )
    }
  }

  private static func validateConfigText(_ value: String, maximumBytes: Int) throws {
    guard !value.isEmpty, value.utf8.count <= maximumBytes, !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw DeepSeekHarnessACPError.malformedResponse
    }
  }

  private static func validateConfigValue(_ value: String, maximumBytes: Int) throws {
    guard value.utf8.count <= maximumBytes, !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw DeepSeekHarnessACPError.malformedResponse
    }
  }

  private static func parseConfigValues(
    _ rawValues: [ACPJSONValue],
    seenValues: inout Set<String>,
    depth: Int
  ) throws -> [DeepSeekHarnessACPConfigValue] {
    guard depth <= 2 else { throw DeepSeekHarnessACPError.malformedResponse }
    return try rawValues.flatMap { rawValue in
      guard let entry = rawValue.objectValue else {
        throw DeepSeekHarnessACPError.malformedResponse
      }
      if let value = entry["value"]?.stringValue {
        guard let name = entry["name"]?.stringValue,
          seenValues.count < 512,
          seenValues.insert(value).inserted
        else {
          throw DeepSeekHarnessACPError.malformedResponse
        }
        try validateConfigValue(value, maximumBytes: 256)
        try validateConfigText(name, maximumBytes: 512)
        return [DeepSeekHarnessACPConfigValue(value: value, name: name)]
      }

      guard let nested = entry["options"]?.arrayValue, nested.count <= 512 else {
        throw DeepSeekHarnessACPError.malformedResponse
      }
      if let group = entry["group"]?.stringValue {
        try validateConfigText(group, maximumBytes: 256)
      }
      if let name = entry["name"]?.stringValue {
        try validateConfigText(name, maximumBytes: 512)
      }
      guard entry["value"] == nil else {
        throw DeepSeekHarnessACPError.malformedResponse
      }
      return try parseConfigValues(nested, seenValues: &seenValues, depth: depth + 1)
    }
  }

  static func validateAbsolutePath(_ value: String, field: String) throws {
    guard AgentPathSemantics.isAbsolute(value), !value.contains("\0"),
      value.utf8.count <= 16 * 1_024,
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw AgentRuntimeError.invalidRequest(field)
    }
  }

  static func validateIdentifier(_ value: String, field: String) throws {
    guard !value.isEmpty, value.utf8.count <= 1_024, !value.contains("\0"),
      value.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw AgentRuntimeError.invalidRequest(field)
    }
  }

  func validateAbsolutePath(_ value: String, field: String) throws {
    try Self.validateAbsolutePath(value, field: field)
  }

  func validateIdentifier(_ value: String, field: String) throws {
    try Self.validateIdentifier(value, field: field)
  }
}
