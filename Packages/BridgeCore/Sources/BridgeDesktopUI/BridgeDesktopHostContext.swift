import Foundation

public enum BridgeDesktopPlatform: String, Codable, Equatable, Sendable {
  case macOS = "macos"
  case windows
}

public struct BridgeDesktopHostContext: Codable, Equatable, Sendable {
  public let platform: BridgeDesktopPlatform

  public init(platform: BridgeDesktopPlatform) {
    self.platform = platform
  }
}
