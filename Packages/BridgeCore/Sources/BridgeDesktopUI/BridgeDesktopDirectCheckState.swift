import BridgeServiceAppCore

public struct BridgeDesktopDirectCheckState: Codable, Equatable, Sendable {
  public let projects: [BridgeDesktopChoice]
  public let canCheck: Bool
  public let isChecking: Bool
  public let projectID: String?
  public let commandLine: String
  public let workingDirectory: String
  public let result: BridgeDesktopDirectCheckResult?
  public let errorMessage: String?

  public init(projects: [BridgeDesktopChoice], canCheck: Bool, status: DirectCommandCheckStatus) {
    self.projects = projects
    self.canCheck = canCheck
    isChecking = status.isChecking
    projectID = status.projectID
    commandLine = status.commandLine
    workingDirectory = status.workingDirectory
    errorMessage = status.errorMessage
    result = status.result.map {
      BridgeDesktopDirectCheckResult(
        allowed: $0.allowed, message: $0.message, matchedRule: $0.matchedRule,
        executable: $0.executable, workingDirectory: $0.workingDirectory,
        requiresApproval: $0.requiresApproval, nextAction: $0.nextAction)
    }
  }
}

public struct BridgeDesktopDirectCheckResult: Codable, Equatable, Sendable {
  public let allowed: Bool
  public let message: String
  public let matchedRule: String?
  public let executable: String?
  public let workingDirectory: String?
  public let requiresApproval: Bool
  public let nextAction: String
}
