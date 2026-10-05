import Foundation

public enum ServicePermissionMode: String, CaseIterable, Sendable {
  case readOnly = "read-only"
  case full

  public init?(rawValue: String) {
    switch rawValue {
    case "read-only": self = .readOnly
    case "full", "workspace-write": self = .full
    default: return nil
    }
  }

  // Existing SQLite constraints and write-slot indexes use this spelling.
  var databaseValue: String {
    self == .full ? "workspace-write" : rawValue
  }
}

extension ServicePermissionMode: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let mode = Self(rawValue: value) else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Invalid task permission mode."
      )
    }
    self = mode
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}
