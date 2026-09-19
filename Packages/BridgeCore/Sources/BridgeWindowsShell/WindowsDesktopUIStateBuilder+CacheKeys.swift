#if os(Windows)
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
    let connectionState: WindowsWorkbenchDisplay.ConnectionState
    let runningTaskCount: Int
    let selectedProjectID: String?
    let permissionMode: String
    let projectItems: [BridgeDesktopProjectRow]
    let taskItems: [BridgeDesktopTaskRow]
    let selectedTaskID: String?
    let selectedTaskDetail: BridgeDesktopTaskDetail?
    let history: BridgeDesktopThreadHistoryState
    let approvalItems: [BridgeDesktopApprovalRow]
    let browserEnabled: Bool
    let supportsImmediateSteer: Bool
    let canLoadEarlierConversation: Bool
    let defaultModel: String?
    let availableModelCount: Int
    let modelError: String?
    let commandReceipt: BridgeDesktopWorkbenchCommandReceipt?
    let browserAvailable: Bool
    let browserURL: String?
    let browserStatus: String?
    let browserCanGoBack: Bool
    let browserCanGoForward: Bool
    let modelRefreshInProgress: Bool
    let canRefreshModels: Bool

    init(
      workbench: WindowsWorkbenchDisplay,
      management: WindowsManagementDisplay,
      browserAvailable: Bool,
      browserURL: String?,
      browserStatus: String?,
      browserCanGoBack: Bool,
      browserCanGoForward: Bool,
      modelRefreshInProgress: Bool,
      canRefreshModels: Bool
    ) {
      connectionState = workbench.connectionState
      runningTaskCount = workbench.runningTaskCount
      selectedProjectID = workbench.selectedProjectID
      permissionMode = workbench.permissionMode
      projectItems = management.project.projectItems
      taskItems = workbench.taskItems
      selectedTaskID = workbench.selectedTaskID
      selectedTaskDetail = workbench.selectedTaskDetail
      history = workbench.history
      approvalItems = workbench.approvalItems
      browserEnabled = workbench.browserEnabled
      supportsImmediateSteer = workbench.supportsImmediateSteer
      canLoadEarlierConversation = workbench.canLoadEarlierConversation
      defaultModel = workbench.defaultModel
      availableModelCount = workbench.availableModelCount
      modelError = workbench.modelError
      commandReceipt = workbench.commandReceipt
      self.browserAvailable = browserAvailable
      self.browserURL = browserURL
      self.browserStatus = browserStatus
      self.browserCanGoBack = browserCanGoBack
      self.browserCanGoForward = browserCanGoForward
      self.modelRefreshInProgress = modelRefreshInProgress
      self.canRefreshModels = canRefreshModels
    }
  }

  struct WindowsDesktopProjectsWorkspaceCacheKey: Equatable {
    let selectedProjectID: String?
    let fileWritePermission: String
    let commandMode: String
    let commandModeValues: [String]
    let commands: [BridgeDesktopWorkspaceCommand]
    let blacklist: [BridgeDesktopBlacklistRule]
    let saveModeEnabled: Bool
    let saveCommandEnabled: Bool
    let removeCommandEnabled: Bool
    let saveBlacklistEnabled: Bool
    let removeBlacklistEnabled: Bool
    let verificationCommands: [String]
    let threadCount: Int?
    let threads: [BridgeDesktopThreadRow]
    let selectedThreadID: String?
    let selectedThreadTitle: String?
    let selectedThreadConversation: [BridgeDesktopConversationEntry]
    let skills: [BridgeDesktopSkillRow]

    init(_ display: WindowsWorkspaceDisplay) {
      selectedProjectID = display.selectedProjectID
      fileWritePermission = display.fileWritePermission
      commandMode = display.commandMode
      commandModeValues = display.commandModeValues
      commands = display.commands
      blacklist = display.blacklist
      saveModeEnabled = display.saveModeEnabled
      saveCommandEnabled = display.saveCommandEnabled
      removeCommandEnabled = display.removeCommandEnabled
      saveBlacklistEnabled = display.saveBlacklistEnabled
      removeBlacklistEnabled = display.removeBlacklistEnabled
      verificationCommands = display.verificationCommands
      threadCount = display.threadCount
      threads = display.threads
      selectedThreadID = display.selectedThreadID
      selectedThreadTitle = display.selectedThreadTitle
      selectedThreadConversation = display.selectedThreadConversation
      skills = display.skills
    }
  }

  struct WindowsDesktopProjectsCacheKey: Equatable {
    let selectedProjectIndex: Int?
    let projectItems: [BridgeDesktopProjectRow]
    let detailText: String
    let registerEnabled: Bool
    let removeEnabled: Bool
    let savePolicyEnabled: Bool
    let workspace: WindowsDesktopProjectsWorkspaceCacheKey?
    let taskItems: [BridgeDesktopTaskRow]

    init(
      workbench: WindowsWorkbenchDisplay,
      management: WindowsManagementDisplay,
      workspace: WindowsWorkspaceDisplay?
    ) {
      selectedProjectIndex = management.project.selectedIndex
      projectItems = management.project.projectItems
      detailText = management.project.detailText
      registerEnabled = management.project.registerEnabled
      removeEnabled = management.project.removeEnabled
      savePolicyEnabled = management.project.savePolicyEnabled
      self.workspace = workspace.map(WindowsDesktopProjectsWorkspaceCacheKey.init)
      taskItems = workbench.taskItems
    }
  }
#endif
