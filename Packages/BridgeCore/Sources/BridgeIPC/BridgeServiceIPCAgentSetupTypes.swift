import Foundation

public struct IPCAgentSetupRequest: Codable, Equatable, Sendable {
  public let providerID: String
  public let qoderDistribution: String?
  public let installationID: String?
  public let installDirectory: String?

  public init(
    providerID: String, qoderDistribution: String? = nil,
    installationID: String? = nil, installDirectory: String? = nil
  ) {
    self.providerID = providerID
    self.qoderDistribution = qoderDistribution
    self.installationID = installationID
    self.installDirectory = installDirectory
  }
}

public struct IPCAgentSetupContinueRequest: Codable, Equatable, Sendable {
  public let operationID: String
  public let installationID: String?
  public let baseURL: String?
  public let apiKey: String?
  public let inferenceProtocol: String?
  public let catalogBaseURL: String?
  public let alwaysProceedConfirmed: Bool
  public let loginCompleted: Bool?

  public init(
    operationID: String, installationID: String? = nil,
    baseURL: String? = nil, apiKey: String? = nil,
    inferenceProtocol: String? = nil, catalogBaseURL: String? = nil,
    alwaysProceedConfirmed: Bool = false, loginCompleted: Bool = false
  ) {
    self.operationID = operationID
    self.installationID = installationID
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.inferenceProtocol = inferenceProtocol
    self.catalogBaseURL = catalogBaseURL
    self.alwaysProceedConfirmed = alwaysProceedConfirmed
    self.loginCompleted = loginCompleted
  }
}

public struct IPCAgentSetupIDRequest: Codable, Equatable, Sendable {
  public let operationID: String

  public init(operationID: String) { self.operationID = operationID }
}

public struct IPCAgentSetupCandidate: Codable, Equatable, Sendable {
  public let installationID: String
  public let executablePath: String
  public let displayName: String

  public init(installationID: String, executablePath: String, displayName: String) {
    self.installationID = installationID
    self.executablePath = executablePath
    self.displayName = displayName
  }
}

public struct IPCAgentSetupLoginCommand: Codable, Equatable, Sendable {
  public let executablePath: String
  public let arguments: [String]
  public let workingDirectory: String
  public let environment: [String: String]
  public let instructions: String
  public let documentationURL: String?

  public init(
    executablePath: String, arguments: [String] = [], workingDirectory: String,
    environment: [String: String] = [:], instructions: String,
    documentationURL: String? = nil
  ) {
    self.executablePath = executablePath
    self.arguments = arguments
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.instructions = instructions
    self.documentationURL = documentationURL
  }
}

public struct IPCAgentSetupState: Codable, Equatable, Sendable {
  public let operationID: String
  public let providerID: String
  public let distribution: String?
  public var state: String
  public var message: String
  public var installationDirectory: String?
  public var executablePath: String?
  public var version: String?
  public var installationID: String?
  public var userAction: String?
  public var loginCommand: IPCAgentSetupLoginCommand?
  public var candidates: [IPCAgentSetupCandidate]

  public init(
    operationID: String, providerID: String, distribution: String? = nil,
    state: String = "checking", message: String = "正在检查安装…",
    installationDirectory: String? = nil, executablePath: String? = nil,
    version: String? = nil, installationID: String? = nil,
    userAction: String? = nil, loginCommand: IPCAgentSetupLoginCommand? = nil,
    candidates: [IPCAgentSetupCandidate] = []
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
    self.loginCommand = loginCommand
    self.candidates = candidates
  }

  public var isRunning: Bool {
    ["checking", "installing", "configuring", "verifying"].contains(state)
  }
}
