public struct ServiceDirectCommandCheckResult: Equatable, Sendable {
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
    allowed: Bool, code: String, message: String,
    matchedRule: String? = nil, ruleSource: String? = nil,
    executable: String? = nil, workingDirectory: String? = nil,
    requiresApproval: Bool = false, nextAction: String
  ) {
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
