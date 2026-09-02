#if os(Windows)
  import BridgeDesktopUI

  extension WindowsDesktopUIStateBuilder {
    static func settingsPage(
      settings: WindowsSettingsDisplay?,
      agentDefaults: WindowsAgentDefaultsDisplay?
    ) -> BridgeDesktopSettingsState? {
      guard let settings else { return nil }
      let defaults = agentDefaults.flatMap(agentDefaultState)
      return BridgeDesktopSettingsState(
        header: header(
          "设置",
          "配置模型、执行偏好、安全策略与全局指令。",
          "gearshape"
        ),
        models: settings.modelOptions,
        executionModel: settings.executionModel,
        executionEffort: settings.executionEffort,
        supervisorModel: settings.supervisorModel,
        supervisorEffort: settings.supervisorEffort,
        supervisorAvailable: false,
        effortOptions: settings.effortValues.map { effortChoice($0) },
        supervisorEffortOptions: settings.effortValues.map { effortChoice($0) },
        accessMode: settings.accessMode,
        accessOptions: settings.accessValues.map { accessChoice($0) },
        supervisorEnabled: false,
        fastModeEnabled: settings.fastModeEnabled,
        directApprovalMode: settings.directApprovalMode,
        directApprovalOptions: settings.directApprovalValues.map { approvalChoice($0) },
        taskStartApprovalMode: settings.taskStartApprovalMode,
        taskStartApprovalOptions: settings.taskStartApprovalValues.map { approvalChoice($0) },
        customInstructions: settings.customInstructions,
        agentDefaults: defaults.map { [$0] } ?? [],
        keepServiceRunningAfterExit: true,
        serviceRegistered: false,
        canSavePreferences: settings.savePreferencesEnabled,
        canSaveInstructions: settings.saveInstructionsEnabled,
        canSaveApprovalModes: settings.saveDirectApprovalEnabled
          && settings.saveTaskStartApprovalEnabled,
        canChangeService: false,
        servicePlatform: "Windows",
        serviceDescription: "后台 Service 按需启动，关闭窗口后继续运行。",
        statusMessage: settings.statusText
      )
    }

    private static func agentDefaultState(
      _ display: WindowsAgentDefaultsDisplay
    ) -> BridgeDesktopAgentDefaultState? {
      guard let providerID = display.selectedProviderID,
        let provider = display.providerItems.first(where: { $0.providerID == providerID })
      else { return nil }
      let installation = display.selectedInstallationID.flatMap { id in
        display.installationItems.first(where: { $0.installationID == id })
      }
      return BridgeDesktopAgentDefaultState(
        providerID: provider.providerID,
        providerName: provider.displayName,
        installationID: installation?.installationID,
        installationName: installation?.displayName,
        model: display.selectedModelID,
        modelOptions: display.modelOptions,
        effort: display.selectedEffort.isEmpty ? nil : display.selectedEffort,
        effortOptions: display.effortValues.map { effortChoice($0, includesDefault: true) },
        permissionMode: display.selectedPermissionMode,
        permissionOptions: display.permissionValues.map { permissionChoice($0) },
        canSave: display.saveEnabled,
        canRefreshModels: display.refreshModelsEnabled,
        isRefreshingModels: false,
        errorMessage: display.defaultErrorMessage
      )
    }

    private static func effortChoice(
      _ value: String,
      includesDefault: Bool = false
    ) -> BridgeDesktopChoice {
      let title: String
      switch value {
      case "": title = "Provider 默认"
      case "none": title = "无"
      case "minimal": title = "最低"
      case "low": title = "低"
      case "medium": title = "中"
      case "high": title = "高"
      case "xhigh", "extra_high": title = "极高"
      case "max": title = "最高"
      case "ultra": title = "Ultra"
      default: title = value
      }
      return choice(value, title, enabled: includesDefault || !value.isEmpty)
    }

    private static func accessChoice(_ value: String) -> BridgeDesktopChoice {
      let title: String
      switch value {
      case "request-approval": title = "请求批准"
      case "auto-review": title = "自动评审"
      case "full-access": title = "完全访问"
      default: title = value
      }
      return choice(value, title)
    }

    private static func approvalChoice(_ value: String) -> BridgeDesktopChoice {
      choice(value, value == "auto" ? "自动" : "每次询问")
    }
  }
#endif
