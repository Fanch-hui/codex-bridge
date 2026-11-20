import Foundation

public struct IPCMessageCenterSecretRequest: Codable, Equatable, Sendable {
  public let action: String
  public let reference: String
  public let value: String?

  public init(action: String, reference: String, value: String? = nil) {
    self.action = action
    self.reference = reference
    self.value = value
  }
}

public struct IPCMessageCenterSecretResponse: Codable, Equatable, Sendable {
  public let value: String?

  public init(value: String? = nil) {
    self.value = value
  }
}
