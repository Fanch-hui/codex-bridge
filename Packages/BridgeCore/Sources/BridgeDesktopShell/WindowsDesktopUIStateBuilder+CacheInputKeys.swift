#if os(Windows) || os(Linux)
  struct WindowsDesktopLogsCacheKey: Equatable {
    let display: WindowsLogDisplay?

    init(_ display: WindowsLogDisplay?) {
      self.display = display
    }
  }

  struct WindowsDesktopConnectionsCacheKey: Equatable {
    struct Workbench: Equatable {
      let connectionState: WindowsWorkbenchDisplay.ConnectionState
      let mcpState: String
      let availableModelCount: Int
      let modelError: String?

      init(_ display: WindowsWorkbenchDisplay) {
        connectionState = display.connectionState
        mcpState = display.mcpState
        availableModelCount = display.availableModelCount
        modelError = display.modelError
      }
    }

    struct Management: Equatable {
      let availableAgentCount: Int
      let agent: WindowsAgentManagementDisplay

      init(_ display: WindowsManagementDisplay) {
        availableAgentCount = display.availableAgentCount
        agent = display.agent
      }
    }

    let workbench: Workbench
    let management: Management
    let connection: WindowsConnectionDisplay?
    let settings: WindowsSettingsDisplay?

    init(
      workbench: WindowsWorkbenchDisplay,
      management: WindowsManagementDisplay,
      connections: WindowsConnectionDisplay?,
      settings: WindowsSettingsDisplay?
    ) {
      self.workbench = Workbench(workbench)
      self.management = Management(management)
      connection = connections
      self.settings = settings
    }
  }

  struct WindowsDesktopSettingsCacheKey: Equatable {
    let settings: WindowsSettingsDisplay?
    let agentDefaults: WindowsAgentDefaultsDisplay?
  }
#endif
