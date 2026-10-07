import Foundation

public struct BridgeDesktopDirectState: Codable, Equatable, Sendable {
  public let commandMode: String
  public let allowedCommands: [String]
  public let deniedCommands: [String]
  public let usesProjectDefaults: Bool
  public let canSave: Bool
  public let check: BridgeDesktopDirectCheckState?

  public init(
    commandMode: String, allowedCommands: [String], deniedCommands: [String],
    usesProjectDefaults: Bool = false, canSave: Bool,
    check: BridgeDesktopDirectCheckState? = nil
  ) {
    self.commandMode = commandMode
    self.allowedCommands = allowedCommands
    self.deniedCommands = deniedCommands
    self.usesProjectDefaults = usesProjectDefaults
    self.canSave = canSave
    self.check = check
  }
}
