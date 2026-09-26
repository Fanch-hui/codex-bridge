import Foundation

public enum AgentInputModality: String, Codable, Equatable, Hashable, Sendable {
  case text
  case image
}

public enum AgentImageAttachmentLimits {
  public static let maximumCount = 8
  public static let maximumTotalBytes: Int64 = 8 * 1_024 * 1_024
  public static let maximumBytesPerAttachment = 8 * 1_024 * 1_024
  public static let supportedMIMETypes: Set<String> = [
    "image/jpeg", "image/png", "image/webp",
  ]
}

public struct AgentImageAttachment: Codable, Equatable, Sendable {
  public let relativePath: String
  public let mimeType: String
  public let byteCount: Int64
  public let sha256: String

  public init(relativePath: String, mimeType: String, byteCount: Int64, sha256: String) throws {
    self.relativePath = try Self.validatedRelativePath(relativePath)
    guard AgentImageAttachmentLimits.supportedMIMETypes.contains(mimeType) else {
      throw AgentRuntimeError.invalidRequest("attachment.mimeType")
    }
    guard byteCount > 0,
      byteCount <= Int64(AgentImageAttachmentLimits.maximumBytesPerAttachment)
    else {
      throw AgentRuntimeError.invalidRequest("attachment.byteCount")
    }
    guard Self.isSHA256(sha256) else {
      throw AgentRuntimeError.invalidRequest("attachment.sha256")
    }
    self.mimeType = mimeType
    self.byteCount = byteCount
    self.sha256 = sha256
  }

  private enum CodingKeys: String, CodingKey {
    case relativePath
    case mimeType
    case byteCount
    case sha256
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      relativePath: values.decode(String.self, forKey: .relativePath),
      mimeType: values.decode(String.self, forKey: .mimeType),
      byteCount: values.decode(Int64.self, forKey: .byteCount),
      sha256: values.decode(String.self, forKey: .sha256)
    )
  }

  private static func validatedRelativePath(_ value: String) throws -> String {
    let portable = value
    let components = portable.split(separator: "/", omittingEmptySubsequences: false)
    guard value.utf8.count <= 2_048,
      !value.isEmpty,
      !value.contains("\0"),
      !value.contains("\\"),
      value.rangeOfCharacter(from: .controlCharacters) == nil,
      !portable.hasPrefix("/"),
      !portable.hasPrefix("~"),
      !portable.lowercased().hasPrefix("file:"),
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
      !components.contains(where: { $0.contains(":") })
    else {
      throw AgentRuntimeError.invalidRequest("attachment.relativePath")
    }
    return components.joined(separator: "/")
  }

  private static func isSHA256(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { byte in
        (48...57).contains(byte) || (97...102).contains(byte)
      }
  }
}
