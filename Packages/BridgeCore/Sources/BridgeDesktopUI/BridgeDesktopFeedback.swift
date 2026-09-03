import Foundation

public enum BridgeDesktopFeedbackKind: String, Codable, Equatable, Sendable {
  case toast
  case alert
}

public struct BridgeDesktopFeedback: Codable, Equatable, Sendable {
  public let id: String
  public let kind: BridgeDesktopFeedbackKind
  public let tone: BridgeDesktopStatusTone
  public let title: String
  public let message: String

  public init(
    id: String,
    kind: BridgeDesktopFeedbackKind,
    tone: BridgeDesktopStatusTone,
    title: String,
    message: String
  ) {
    self.id = id
    self.kind = kind
    self.tone = tone
    self.title = title
    self.message = message
  }
}
