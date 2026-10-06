import BridgeAgentCore
import Foundation

public enum DeepSeekHarnessDesktopAction: String, Codable, Sendable {
  case status, connect, setMode, installConnector, pair, revoke, openSession
}

public struct DeepSeekHarnessDesktopRequest: Codable, Equatable, Sendable {
  public let installationID: String
  public let action: DeepSeekHarnessDesktopAction
  public let mode: DeepSeekHarnessConnectionMode?
  public let projectID: String?
  public let sessionID: String?
  public let taskID: String?

  public init(
    installationID: String, action: DeepSeekHarnessDesktopAction = .status,
    mode: DeepSeekHarnessConnectionMode? = nil, projectID: String? = nil, sessionID: String? = nil,
    taskID: String? = nil
  ) {
    self.installationID = installationID
    self.action = action
    self.mode = mode
    self.projectID = projectID
    self.sessionID = sessionID
    self.taskID = taskID
  }
}

public struct DeepSeekHarnessDesktopState: Codable, Equatable, Sendable {
  public let mode: DeepSeekHarnessConnectionMode
  public let desktop: DeepSeekHarnessDesktopStatus
  public let executablePath: String
  public let connectorInstalled: Bool
  public let canInstallConnector: Bool
  public let canOpenSession: Bool
  public let canListSessions: Bool
  public let canRenameSession: Bool
  public let canDeleteSession: Bool

  public init(
    mode: DeepSeekHarnessConnectionMode, desktop: DeepSeekHarnessDesktopStatus,
    executablePath: String, connectorInstalled: Bool = false, canInstallConnector: Bool = false
  ) {
    self.mode = mode
    self.desktop = desktop
    self.executablePath = executablePath
    self.connectorInstalled = connectorInstalled
    self.canInstallConnector = canInstallConnector
    self.canOpenSession = desktop.paired
    self.canListSessions = mode == .nativeDesktop && desktop.connected && desktop.paired
    self.canRenameSession = canListSessions
    self.canDeleteSession = false
  }
}

extension BridgeServiceClient {
  public func connectAgentInstallation(_ request: IPCAgentConnectRequest) async throws
    -> IPCAgentInstallationSummary
  {
    try await call(operation: .connectAgentInstallation, payload: request)
  }
  public func manageDeepSeekHarnessDesktop(_ request: DeepSeekHarnessDesktopRequest) async throws
    -> DeepSeekHarnessDesktopState
  {
    try await call(operation: .manageDeepSeekHarnessDesktop, payload: request)
  }
}
