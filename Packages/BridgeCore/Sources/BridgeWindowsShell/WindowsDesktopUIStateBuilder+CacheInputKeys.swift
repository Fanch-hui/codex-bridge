#if os(Windows)
  import BridgeDesktopUI

  struct WindowsDesktopLogsCacheKey: Equatable {
    let display: Display?

    struct Display: Equatable {
      let searchText: String
      let projectOptions: [BridgeDesktopChoice]
      let selectedProjectID: String?
      let selectedKind: String
      let rows: [BridgeDesktopLogRow]
      let selectedRowID: String?
      let detailText: String
      let copyEnabled: Bool
      let refreshEnabled: Bool

      init(_ display: WindowsLogDisplay) {
        searchText = display.searchText
        projectOptions = display.projectOptions
        selectedProjectID = display.selectedProjectID
        selectedKind = display.selectedKind
        rows = display.rowsTyped
        selectedRowID = display.selectedRowID
        detailText = display.detailText
        copyEnabled = display.copyEnabled
        refreshEnabled = display.refreshEnabled
      }
    }

    init(_ display: WindowsLogDisplay?) {
      self.display = display.map(Display.init)
    }
  }

  struct WindowsDesktopConnectionsCacheKey: Equatable {
    struct Workbench: Equatable {
      let connectionState: WindowsWorkbenchDisplay.ConnectionState
      let mcpState: String
      let availableModelCount: Int?
      let modelError: String?
    }

    struct Management: Equatable {
      let availableAgentCount: Int
      let agentStatusText: String
      let providerItems: [BridgeDesktopAgentProviderRow]
      let installationItems: [BridgeDesktopAgentInstallationRow]
      let registerEnabled: Bool
      let isManagingAgents: Bool
      let agentOperationRevision: Int
    }

    struct Connection: Equatable {
      let connectionState: WindowsWorkbenchDisplay.ConnectionState
      let endpointText: String
      let rotateEndpointEnabled: Bool
      let tunnel: BridgeDesktopTunnelState?
      let clientItems: [BridgeDesktopMCPClientRow]
      let deepSeekHarnessMCPItems: [BridgeDesktopDeepSeekHarnessMCPRow]
      let statusText: String
      let codexExecutablePath: String?
      let codexResolvedExecutablePath: String?

      init(_ display: WindowsConnectionDisplay) {
        connectionState = display.connectionState
        endpointText = display.endpointText
        rotateEndpointEnabled = display.rotateEndpointEnabled
        tunnel = display.tunnel
        clientItems = display.clientItems
        deepSeekHarnessMCPItems = display.deepSeekHarnessMCPItems
        statusText = display.statusText
        codexExecutablePath = display.codexExecutablePath
        codexResolvedExecutablePath = display.codexResolvedExecutablePath
      }
    }

    struct Settings: Equatable {
      let modelCount: Int
      let modelError: String?
      let isRefreshingModels: Bool
      let busy: Bool

      init(_ display: WindowsSettingsDisplay) {
        modelCount = display.modelOptions.count
        modelError = display.modelError
        isRefreshingModels = display.isRefreshingModels
        busy = display.busy
      }
    }

    let workbench: Workbench
    let management: Management
    let connection: Connection?
    let settings: Settings?

    init(
      workbench: WindowsWorkbenchDisplay,
      management: WindowsManagementDisplay,
      connections: WindowsConnectionDisplay?,
      settings: WindowsSettingsDisplay?
    ) {
      let settings = settings.flatMap { $0.connectionState != .idle || $0.busy ? $0 : nil }
      self.workbench = Workbench(
        connectionState: workbench.connectionState,
        mcpState: workbench.mcpState,
        availableModelCount: settings == nil ? workbench.availableModelCount : nil,
        modelError: settings == nil ? workbench.modelError : nil
      )
      self.management = Management(
        availableAgentCount: management.availableAgentCount,
        agentStatusText: management.agent.statusText,
        providerItems: management.agent.providerItems,
        installationItems: management.agent.installationItems,
        registerEnabled: management.agent.registerEnabled,
        isManagingAgents: management.agent.isManagingAgents,
        agentOperationRevision: management.agent.agentOperationRevision
      )
      connection = connections.map(Connection.init)
      self.settings = settings.map(Settings.init)
    }
  }

  struct WindowsDesktopSettingsCacheKey: Equatable {
    struct Settings: Equatable {
      let modelOptions: [BridgeDesktopModelOption]
      let executionModel: String
      let executionEffort: String
      let accessMode: String
      let accessValues: [String]
      let fastModeEnabled: Bool
      let directApprovalMode: String
      let directApprovalValues: [String]
      let taskStartApprovalMode: String
      let taskStartApprovalValues: [String]
      let customInstructions: String
      let savePreferencesEnabled: Bool
      let saveInstructionsEnabled: Bool
      let saveDirectApprovalEnabled: Bool
      let saveTaskStartApprovalEnabled: Bool
      let statusText: String
      let busy: Bool
      let isRefreshingModels: Bool
      let modelError: String?
      let keepServiceRunningAfterExit: Bool
      let serviceRegistered: Bool
      let direct: BridgeDesktopDirectState?

      init(_ display: WindowsSettingsDisplay) {
        modelOptions = display.modelOptions
        executionModel = display.executionModel
        executionEffort = display.executionEffort
        accessMode = display.accessMode
        accessValues = display.accessValues
        fastModeEnabled = display.fastModeEnabled
        directApprovalMode = display.directApprovalMode
        directApprovalValues = display.directApprovalValues
        taskStartApprovalMode = display.taskStartApprovalMode
        taskStartApprovalValues = display.taskStartApprovalValues
        customInstructions = display.customInstructions
        savePreferencesEnabled = display.savePreferencesEnabled
        saveInstructionsEnabled = display.saveInstructionsEnabled
        saveDirectApprovalEnabled = display.saveDirectApprovalEnabled
        saveTaskStartApprovalEnabled = display.saveTaskStartApprovalEnabled
        statusText = display.statusText
        busy = display.busy
        isRefreshingModels = display.isRefreshingModels
        modelError = display.modelError
        keepServiceRunningAfterExit = display.keepServiceRunningAfterExit
        serviceRegistered = display.serviceRegistered
        direct = display.direct
      }
    }

    struct AgentDefaults: Equatable {
      let defaultItems: [BridgeDesktopAgentDefaultState]
      let nativePermissionPolicy: BridgeDesktopNativePermissionState?

      init(_ display: WindowsAgentDefaultsDisplay) {
        defaultItems = display.defaultItems
        nativePermissionPolicy = display.nativePermissionPolicy
      }
    }

    let settings: Settings?
    let agentDefaults: AgentDefaults?

    init(
      settings: WindowsSettingsDisplay?,
      agentDefaults: WindowsAgentDefaultsDisplay?
    ) {
      self.settings = settings.map(Settings.init)
      self.agentDefaults = agentDefaults.map(AgentDefaults.init)
    }
  }
#endif
