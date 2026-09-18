#if os(Windows)
  import BridgeDesktopUI
  @testable import BridgeWindowsShell

  func makeWorkbench(
    taskCount: Int = 0,
    runningTaskCount: Int = 0,
    pendingApprovalCount: Int = 0,
    projectRows: [String] = [],
    recentTaskRows: [String] = [],
    recentTasks: [WindowsRecentTaskPresentation] = []
  ) -> WindowsWorkbenchDisplay {
    WindowsWorkbenchDisplay(
      connectionState: .connected,
      mcpAddress: "http://127.0.0.1:58720/mcp",
      mcpState: "ready",
      taskCount: taskCount,
      runningTaskCount: runningTaskCount,
      pendingApprovalCount: pendingApprovalCount,
      projectRows: projectRows,
      selectedProjectIndex: nil,
      permissionRows: ["只读", "可写"],
      selectedPermissionIndex: 1,
      taskRows: [],
      recentTaskRows: recentTaskRows,
      recentTasks: recentTasks,
      selectedTaskID: nil,
      selectedTaskIndex: nil,
      taskMetadata: "未选择任务",
      interruptEnabled: false,
      stopEnabled: false,
      deleteEnabled: false,
      steerEnabled: false,
      actionText: nil,
      approvalRows: [],
      selectedApprovalIndex: nil,
      approvalDetailText: "",
      approvalAllowDecisions: [],
      approvalAllowEnabled: false,
      approvalDenyEnabled: false,
      approvalStatusText: nil,
      detailText: nil
    )
  }

  func makeManagement(
    availableAgentCount: Int = 0,
    installationCount: Int = 0,
    installationItems: [BridgeDesktopAgentInstallationRow] = []
  ) -> WindowsManagementDisplay {
    WindowsManagementDisplay(
      connectionState: .connected,
      availableAgentCount: availableAgentCount,
      project: WindowsProjectManagementDisplay(
        rows: ["Bridge"],
        selectedIndex: 0,
        detailText: "",
        policy: nil,
        registerEnabled: false,
        removeEnabled: false,
        savePolicyEnabled: false,
        statusText: ""
      ),
      agent: WindowsAgentManagementDisplay(
        providerRows: [],
        providerIDs: [],
        selectedProviderIndex: nil,
        providerDetailText: "",
        providerRequiresConfiguration: false,
        installationRows: installationItems.isEmpty
          ? Array(repeating: "Agent", count: installationCount)
          : installationItems.map(\.displayName),
        selectedInstallationIndex: nil,
        installationDetailText: "",
        registerEnabled: false,
        enableEnabled: false,
        disableEnabled: false,
        reprobeEnabled: false,
        acceptReplacementEnabled: false,
        removeEnabled: false,
        statusText: "",
        installationItems: installationItems
      )
    )
  }

  func makeAgentInstallationRow(
    displayName: String,
    enabled: Bool,
    availability: String
  ) -> BridgeDesktopAgentInstallationRow {
    BridgeDesktopAgentInstallationRow(
      installationID: displayName,
      providerID: "opencode",
      displayName: displayName,
      executablePath: "C:/fixture/agent.exe",
      adapterRevision: 1,
      trustProfile: "managed",
      enabled: enabled,
      availability: availability,
      updatedAt: ""
    )
  }

  func makeTunnel(
    lifecycle: String,
    enabled: Bool,
    configured: Bool = true,
    helperAvailable: Bool = true,
    acceptsRemoteSubmissions: Bool = false,
    actionRequired: Bool = false
  ) -> BridgeDesktopTunnelState {
    BridgeDesktopTunnelState(
      configured: configured,
      enabled: enabled,
      helperAvailable: helperAvailable,
      tunnelID: configured ? "tunnel-9" : nil,
      lifecycle: lifecycle,
      acceptsRemoteSubmissions: acceptsRemoteSubmissions,
      actionRequired: actionRequired,
      canConfigure: helperAvailable,
      canConnect: configured && helperAvailable && !enabled,
      canDisconnect: enabled,
      canClear: configured
    )
  }

  func makeConnections(tunnel: BridgeDesktopTunnelState?) -> WindowsConnectionDisplay {
    WindowsConnectionDisplay(
      connectionState: .connected,
      clientRows: [],
      selectedClientIndex: nil,
      clientDetailText: "",
      endpointText: "http://127.0.0.1:58720/mcp",
      exposureRows: ["只读", "完整"],
      selectedExposureIndex: nil,
      toggleTitle: "",
      toggleEnabled: false,
      saveExposureEnabled: false,
      copyConfigurationEnabled: false,
      rotateCredentialEnabled: false,
      rotateEndpointEnabled: false,
      statusText: "",
      tunnel: tunnel
    )
  }

  func makeSettings(
    connectionState: WindowsWorkbenchDisplay.ConnectionState = .connected,
    keepServiceRunningAfterExit: Bool = true,
    serviceRegistered: Bool = false
  ) -> WindowsSettingsDisplay {
    WindowsSettingsDisplay(
      connectionState: connectionState,
      modelRows: [],
      modelIDs: [],
      selectedExecutionModelIndex: nil,
      effortValues: [],
      selectedExecutionEffortIndex: nil,
      accessValues: ["request-approval"],
      selectedAccessIndex: 0,
      fastModeEnabled: false,
      directApprovalValues: ["require"],
      selectedDirectApprovalIndex: 0,
      taskStartApprovalValues: ["require"],
      selectedTaskStartApprovalIndex: 0,
      customInstructions: "",
      savePreferencesEnabled: false,
      saveInstructionsEnabled: false,
      saveDirectApprovalEnabled: false,
      saveTaskStartApprovalEnabled: false,
      statusText: "就绪",
      keepServiceRunningAfterExit: keepServiceRunningAfterExit,
      serviceRegistered: serviceRegistered
    )
  }
#endif
