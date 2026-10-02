#if os(Windows) || os(Linux)
  import BridgeDesktopUI

  struct WindowsDesktopNavigationCacheKey: Equatable {
    let runningTaskCount: Int
    let pendingApprovalCount: Int
    let projectCount: Int
  }

  struct WindowsDesktopOverviewCacheKey: Equatable {
    let connectionState: WindowsWorkbenchDisplay.ConnectionState
    let mcpState: String
    let detailText: String?
    let runningTaskCount: Int
    let pendingApprovalCount: Int
    let taskCount: Int
    let projectCount: Int
    let installationCount: Int
    let availableAgentCount: Int
    let agentReconnectSummary: String?
    let recentTasks: [WindowsRecentTaskPresentation]
    let tunnel: BridgeDesktopTunnelState?
  }

  struct WindowsDesktopWorkbenchCacheKey: Equatable {
    let workbench: WindowsWorkbenchDisplay
    let management: WindowsManagementDisplay
    let settings: WindowsSettingsDisplay?
    let browserAvailable: Bool
    let browserURL: String?
    let browserStatus: String?
    let browserCanGoBack: Bool
    let browserCanGoForward: Bool
  }

  struct WindowsDesktopProjectsCacheKey: Equatable {
    let project: WindowsProjectManagementDisplay
    let workspace: WindowsWorkspaceDisplay?
    let taskItems: [BridgeDesktopTaskRow]

    init(
      workbench: WindowsWorkbenchDisplay,
      management: WindowsManagementDisplay,
      workspace: WindowsWorkspaceDisplay?
    ) {
      project = management.project
      self.workspace = workspace
      taskItems = workbench.taskItems
    }
  }
#endif
