import Foundation

public struct BridgeDesktopUIState: Codable, Equatable, Sendable {
  public let hostContext: BridgeDesktopHostContext?
  public let navigation: [BridgeDesktopNavigationItem]
  public let selectedNavigation: BridgeDesktopNavigation
  public let connectionLabel: String
  public let connectionTone: BridgeDesktopStatusTone
  public let isRefreshing: Bool
  public let feedback: BridgeDesktopFeedback?
  public let overview: BridgeDesktopOverviewState?
  public let workbench: BridgeDesktopWorkbenchState?
  public let projects: BridgeDesktopProjectsState?
  public let logs: BridgeDesktopLogsState?
  public let connections: BridgeDesktopConnectionsState?
  public let settings: BridgeDesktopSettingsState?
  public let appUpdate: BridgeDesktopAppUpdateState?

  public init(
    hostContext: BridgeDesktopHostContext? = nil,
    navigation: [BridgeDesktopNavigationItem] = BridgeDesktopNavigation.canonicalItems,
    selectedNavigation: BridgeDesktopNavigation,
    connectionLabel: String,
    connectionTone: BridgeDesktopStatusTone,
    isRefreshing: Bool,
    feedback: BridgeDesktopFeedback? = nil,
    overview: BridgeDesktopOverviewState?,
    workbench: BridgeDesktopWorkbenchState? = nil,
    projects: BridgeDesktopProjectsState? = nil,
    logs: BridgeDesktopLogsState? = nil,
    connections: BridgeDesktopConnectionsState? = nil,
    settings: BridgeDesktopSettingsState? = nil,
    appUpdate: BridgeDesktopAppUpdateState? = nil
  ) {
    self.hostContext = hostContext
    self.navigation = navigation
    self.selectedNavigation = selectedNavigation
    self.connectionLabel = connectionLabel
    self.connectionTone = connectionTone
    self.isRefreshing = isRefreshing
    self.feedback = feedback
    self.overview = overview
    self.workbench = workbench
    self.projects = projects
    self.logs = logs
    self.connections = connections
    self.settings = settings
    self.appUpdate = appUpdate
  }
}
