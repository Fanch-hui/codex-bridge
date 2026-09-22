import BridgeCodexRPC
import Foundation

public enum ServiceLocalMCPError: Error, Equatable, Sendable {
  case localPortUnavailable(Int)
  case endpointManagedByConfiguration
}

public enum ServiceCodexExecutableError: Error, Equatable, Sendable {
  /// The configured path is not a usable Codex executable for this platform.
  case unavailable
}

public struct ServiceMCPClientStatus: Equatable, Sendable {
  public let profile: ServiceMCPClientProfile
  public let activeSessionCount: Int
  public let lastConnectedAt: Date?

  public init(
    profile: ServiceMCPClientProfile,
    activeSessionCount: Int,
    lastConnectedAt: Date?
  ) {
    self.profile = profile
    self.activeSessionCount = activeSessionCount
    self.lastConnectedAt = lastConnectedAt
  }
}

public struct ServiceCompositionConfiguration: Sendable {
  public let appVersion: String
  public let dataRootURL: URL
  /// A pinned Codex app-server configuration; `nil` keeps automatic discovery,
  /// which is re-evaluated on every spawned process.
  public let executionAppServer: AppServerConfiguration?
  public let supervisorAppServer: AppServerConfiguration?
  public let catalogAppServer: AppServerConfiguration?
  public let clientInfo: CodexClientInfo
  public let synchronizeCodexProjects: Bool
  public let mcpPort: Int
  public let appBundleURL: URL?
  public let legacyDataRootURL: URL?

  public init(
    appVersion: String,
    dataRootURL: URL = ServiceDataPaths.defaultRoot(),
    executionAppServer: AppServerConfiguration? = nil,
    supervisorAppServer: AppServerConfiguration? = nil,
    catalogAppServer: AppServerConfiguration? = nil,
    clientInfo: CodexClientInfo,
    synchronizeCodexProjects: Bool = true,
    mcpPort: Int = 0,
    appBundleURL: URL? = ServiceBundleLocator.currentAppBundleURL(),
    legacyDataRootURL: URL? = nil
  ) {
    precondition(!appVersion.isEmpty)
    precondition((0...65_535).contains(mcpPort))
    self.appVersion = appVersion
    self.dataRootURL = dataRootURL
    self.executionAppServer = executionAppServer
    self.supervisorAppServer = supervisorAppServer
    self.catalogAppServer = catalogAppServer
    self.clientInfo = clientInfo
    self.synchronizeCodexProjects = synchronizeCodexProjects
    self.mcpPort = mcpPort
    self.appBundleURL = appBundleURL?.standardizedFileURL
    self.legacyDataRootURL = legacyDataRootURL?.standardizedFileURL
  }
}
