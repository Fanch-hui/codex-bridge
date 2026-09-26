import Foundation

public indirect enum PiJSONValue: Codable, Equatable, Sendable {
  case object([String: PiJSONValue])
  case array([PiJSONValue])
  case string(String)
  case integer(Int64)
  case number(Double)
  case bool(Bool)
  case null

  public init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer()
    if value.decodeNil() {
      self = .null
    } else if let flag = try? value.decode(Bool.self) {
      self = .bool(flag)
    } else if let integer = try? value.decode(Int64.self) {
      self = .integer(integer)
    } else if let number = try? value.decode(Double.self), number.isFinite {
      self = .number(number)
    } else if let text = try? value.decode(String.self) {
      self = .string(text)
    } else if let array = try? value.decode([PiJSONValue].self) {
      self = .array(array)
    } else {
      self = .object(try value.decode([String: PiJSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  public subscript(_ key: String) -> PiJSONValue? { objectValue?[key] }
  public var objectValue: [String: PiJSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }
  public var arrayValue: [PiJSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }
  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }
  public var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }
  public var integerValue: Int? {
    guard case .integer(let value) = self else { return nil }
    return Int(exactly: value)
  }
  public var doubleValue: Double? {
    switch self {
    case .integer(let value): Double(value)
    case .number(let value): value
    default: nil
    }
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  public func text() throws -> String { String(decoding: try encoded(), as: UTF8.self) }
}

public enum PiRPCError: Error, Equatable, Sendable {
  case invalidRecord
  case invalidArgument(String)
  case responseMismatch
  case remote(command: String, message: String)
  case closed
  case timedOut
  case oversizedFrame
  case processExited(Int32?)
  case incompatibleRuntime
}
