import Foundation

public struct BridgeDesktopDeepSeekHarnessDesktopState: Codable, Equatable, Sendable {
  public let installationID: String
  public let mode: String
  public let connected: Bool
  public let paired: Bool
  public let pairingCode: String?
  public let profileID: String?
  public let message: String?
  public let executablePath: String?
  public let connectorInstalled: Bool
  public let canInstallConnector: Bool

  public init(
    installationID: String, mode: String, connected: Bool, paired: Bool,
    pairingCode: String? = nil, profileID: String? = nil, message: String? = nil,
    executablePath: String? = nil,
    connectorInstalled: Bool = false, canInstallConnector: Bool = false
  ) {
    self.installationID = installationID
    self.mode = mode
    self.connected = connected
    self.paired = paired
    self.pairingCode = pairingCode
    self.profileID = profileID
    self.message = message
    self.executablePath = executablePath
    self.connectorInstalled = connectorInstalled
    self.canInstallConnector = canInstallConnector
  }
}
