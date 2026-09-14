import Foundation

public struct BridgeDesktopApprovalOption: Codable, Equatable, Sendable {
  public let label: String
  public let description: String

  public init(label: String, description: String) {
    self.label = label
    self.description = description
  }
}

public struct BridgeDesktopApprovalQuestion: Codable, Equatable, Sendable {
  public let id: String
  public let header: String
  public let question: String
  public let isOther: Bool
  public let isSecret: Bool
  public let options: [BridgeDesktopApprovalOption]

  public init(
    id: String,
    header: String,
    question: String,
    isOther: Bool,
    isSecret: Bool,
    options: [BridgeDesktopApprovalOption]
  ) {
    self.id = id
    self.header = header
    self.question = question
    self.isOther = isOther
    self.isSecret = isSecret
    self.options = options
  }
}
