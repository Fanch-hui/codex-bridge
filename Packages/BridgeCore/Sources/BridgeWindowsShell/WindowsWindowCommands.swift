#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import Foundation

  /// Page vocabulary shared by the command bus and the rendered desktop surface.
  /// Titles and copy live in `BridgeDesktopNavigation`; the host holds no page text.
  enum WindowsMainPage: Int, CaseIterable, Sendable {
    case overview
    case workbench
    case projects
    case logs
    case connections
    case settings
  }

  enum MainWindowCommand: Equatable {
    case selectPage(index: Int)
    case refreshAll
    case openTask(id: String)
    case browserBack
    case browserForward
    case browserReload
    case openChatExternally
    case refreshTasks
    case startService
    case selectTask(index: Int)
    case selectWorkbenchProject(index: Int)
    case selectWorkbenchPermission(index: Int)
    case selectWorkbenchItem(index: Int)
    case interruptSelectedTask
    case stopSelectedTask
    case deleteSelectedTask
    case submitSteer(input: String)
    case selectApproval(index: Int)
    case refreshApprovals
    case resolveApproval(decision: String)
    case selectMCPClient(index: Int)
    case refreshMCPConnections
    case toggleSelectedMCPClient
    case setSelectedMCPExposure(index: Int)
    case copySelectedMCPConfiguration
    case rotateSelectedMCPCredential
    case rotateLocalMCPEndpoint
    case configureTunnel(tunnelID: String, runtimeKey: String)
    case connectTunnel
    case disconnectTunnel
    case clearTunnel
    case selectProject(index: Int)
    case refreshProjects
    case registerProject(name: String, path: String)
    case removeSelectedProject
    case saveProjectPolicy(read: String, write: String, network: String)
    case selectAgentProvider(index: Int)
    case selectAgentInstallation(index: Int)
    case refreshAgents
    case registerAgent(providerID: String, executablePath: String, configurationPath: String)
    case enableSelectedAgent
    case disableSelectedAgent
    case reprobeSelectedAgent(acceptReplacement: Bool)
    case removeSelectedAgent
    case selectWorkspaceProject(index: Int)
    case selectWorkspaceCommand(index: Int)
    case selectWorkspaceSkill(index: Int)
    case selectWorkspaceThread(index: Int)
    case selectWorkspaceBlacklist(index: Int)
    case refreshWorkspace
    case setWorkspaceMode(mode: String)
    case saveWorkspaceCommand(
      name: String,
      executable: String,
      arguments: String,
      workingDirectory: String,
      requiresNetwork: Bool,
      risk: String
    )
    case removeSelectedWorkspaceCommand
    case saveWorkspaceBlacklist(executable: String, pattern: String)
    case removeSelectedWorkspaceBlacklist
    case selectDefaultProvider(index: Int)
    case selectDefaultInstallation(index: Int)
    case refreshAgentDefaults
    case refreshAgentModels
    case saveAgentDefaults(model: String, permissionMode: String, effort: String)
    case refreshLogs
    case selectLog(index: Int)
    case setLogSearch(text: String)
    case setLogProjectFilter(index: Int)
    case setLogKindFilter(index: Int)
    case copyLogs
    case refreshSettings
    case saveSettingsPreferences(preferences: IPCModelPreferences)
    case saveSettingsInstructions(text: String)
    case setSettingsDirectApprovalMode(mode: String)
    case setSettingsTaskStartApprovalMode(mode: String)
    case setBrowserEnabled(enabled: Bool)
    case loadEarlierConversation(taskID: String)
    case refreshConversation(taskID: String)
    case setWorkbenchPermissionMode(mode: String)
    case selectTaskByID(id: String)
    case interruptTask(id: String)
    case stopTask(id: String)
    case deleteTask(id: String)
    case steerTask(id: String, input: String, mode: String)
    case resolveTaskApproval(approvalID: String, taskID: String, decision: String)
    case resolveDirectApproval(id: String, decision: String)
    case selectProjectByID(id: String)
    case beginProjectRegistration
    case removeProject(id: String)
    case saveProjectPolicyByID(
      projectID: String,
      read: String,
      write: String,
      network: String
    )
    case setProjectCommandMode(projectID: String, mode: String)
    case saveProjectCommand(
      projectID: String,
      commandID: String?,
      name: String,
      executable: String,
      arguments: [String],
      workingDirectory: String?,
      requiresNetwork: Bool,
      risk: String
    )
    case removeProjectCommand(projectID: String, commandID: String)
    case saveProjectBlacklist(
      projectID: String,
      ruleID: String?,
      executable: String?,
      pattern: String?
    )
    case removeProjectBlacklist(projectID: String, ruleID: String)
    case openThread(projectID: String, threadID: String)
    case selectLogByID(id: String, taskID: String?)
    case setLogProjectFilterByID(projectID: String?)
    case setLogKindFilterByID(kind: String)
    case setMCPClientEnabled(id: String, enabled: Bool)
    case setMCPClientExposure(id: String, exposureMode: String)
    case copyMCPClientConfiguration(id: String)
    case copyLocalMCPEndpoint
    case rotateMCPClientCredential(id: String)
    case selectAgent(id: String)
    case setAgentEnabled(id: String, enabled: Bool)
    case reprobeAgent(id: String, acceptReplacement: Bool)
    case removeAgent(id: String)
    case registerAgentFromDesktop(
      providerID: String,
      displayName: String,
      executablePath: String,
      configurationPath: String?
    )
    case refreshAgentModelsByID(providerID: String, installationID: String)
    case saveAgentDefault(
      providerID: String,
      installationID: String,
      modelID: String?,
      permissionMode: String,
      effort: String?
    )
    case patchSettings(BridgeDesktopSettingsPatch)
    case updateBrowserViewport(viewport: BridgeDesktopBrowserViewport)
    case dismissFeedback(id: String)
  }
#endif
