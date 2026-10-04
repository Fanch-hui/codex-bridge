public struct BridgeDesktopAgentSetupCandidate: Codable, Equatable, Sendable {
  public let installationID: String
  public let executablePath: String
  public let displayName: String

  public init(installationID: String, executablePath: String, displayName: String) {
    self.installationID = installationID
    self.executablePath = executablePath
    self.displayName = displayName
  }
}

public struct BridgeDesktopAgentSetupState: Codable, Equatable, Sendable {
  public let operationID: String
  public let providerID: String
  public let distribution: String?
  public let state: String
  public let message: String
  public let installationDirectory: String?
  public let executablePath: String?
  public let version: String?
  public let installationID: String?
  public let userAction: String?
  public let loginInstructions: String?
  public let documentationURL: String?
  public let canOpenLogin: Bool
  public let candidates: [BridgeDesktopAgentSetupCandidate]

  public init(
    operationID: String, providerID: String, distribution: String? = nil,
    state: String, message: String, installationDirectory: String? = nil,
    executablePath: String? = nil, version: String? = nil, installationID: String? = nil,
    userAction: String? = nil, loginInstructions: String? = nil,
    documentationURL: String? = nil, canOpenLogin: Bool = false,
    candidates: [BridgeDesktopAgentSetupCandidate] = []
  ) {
    self.operationID = operationID
    self.providerID = providerID
    self.distribution = distribution
    self.state = state
    self.message = message
    self.installationDirectory = installationDirectory
    self.executablePath = executablePath
    self.version = version
    self.installationID = installationID
    self.userAction = userAction
    self.loginInstructions = loginInstructions
    self.documentationURL = documentationURL
    self.canOpenLogin = canOpenLogin
    self.candidates = candidates
  }
}
