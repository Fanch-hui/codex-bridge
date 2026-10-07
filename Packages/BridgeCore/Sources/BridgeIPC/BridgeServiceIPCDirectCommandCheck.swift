import Foundation

public struct IPCDirectCommandCheckRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let commandLine: String
  public let workingDirectory: String?
  public let requestID: String

  public init(
    projectID: String, commandLine: String, workingDirectory: String? = nil, requestID: String
  ) {
    self.projectID = projectID
    self.commandLine = commandLine
    self.workingDirectory = workingDirectory
    self.requestID = requestID
  }
}

public struct IPCDirectCommandCheckResult: Codable, Equatable, Sendable {
  public let projectID: String
  public let requestID: String
  public let allowed: Bool
  public let code: String
  public let message: String
  public let matchedRule: String?
  public let ruleSource: String?
  public let executable: String?
  public let workingDirectory: String?
  public let requiresApproval: Bool
  public let nextAction: String

  public init(
    projectID: String, requestID: String, allowed: Bool, code: String, message: String,
    matchedRule: String? = nil, ruleSource: String? = nil,
    executable: String? = nil, workingDirectory: String? = nil,
    requiresApproval: Bool = false, nextAction: String
  ) {
    self.projectID = projectID
    self.requestID = requestID
    self.allowed = allowed
    self.code = code
    self.message = message
    self.matchedRule = matchedRule
    self.ruleSource = ruleSource
    self.executable = executable
    self.workingDirectory = workingDirectory
    self.requiresApproval = requiresApproval
    self.nextAction = nextAction
  }
}

extension BridgeServiceClient {
  public func checkDirectCommand(_ request: IPCDirectCommandCheckRequest) async throws
    -> IPCDirectCommandCheckResult
  {
    try await call(operation: .checkDirectCommand, payload: request)
  }
}
