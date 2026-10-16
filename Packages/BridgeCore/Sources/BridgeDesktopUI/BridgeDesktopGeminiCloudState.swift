import Foundation

public struct BridgeDesktopGeminiCloudState: Codable, Equatable, Sendable {
  public let hosting: String
  public let baseURL: String
  public let enabled: Bool
  public let lifecycle: String
  public let message: String?
  public let lastConnectedAt: String?
  public let canConfigure: Bool
  public let canExport: Bool

  public init(
    hosting: String = "sites",
    baseURL: String = "",
    enabled: Bool = false,
    lifecycle: String = "stopped",
    message: String? = nil,
    lastConnectedAt: String? = nil,
    canConfigure: Bool = false,
    canExport: Bool = false
  ) {
    self.hosting = hosting
    self.baseURL = baseURL
    self.enabled = enabled
    self.lifecycle = lifecycle
    self.message = message
    self.lastConnectedAt = lastConnectedAt
    self.canConfigure = canConfigure
    self.canExport = canExport
  }
}
