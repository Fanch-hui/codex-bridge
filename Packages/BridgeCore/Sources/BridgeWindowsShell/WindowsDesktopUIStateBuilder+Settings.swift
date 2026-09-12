#if os(Windows)
  import BridgeDesktopUI

  extension WindowsDesktopUIStateBuilder {
    static func settingsPage(
      settings: WindowsSettingsDisplay?,
      agentDefaults: WindowsAgentDefaultsDisplay?
    ) -> BridgeDesktopSettingsState? {
      guard let settings else { return nil }
      let canRefreshModels = !settings.busy
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
        agentDefaults: agentDefaults?.defaultItems ?? [],
        nativePermissionPolicy: agentDefaults?.nativePermissionPolicy,
        keepServiceRunningAfterExit: settings.keepServiceRunningAfterExit,
        serviceRegistered: settings.serviceRegistered,
        canSavePreferences: settings.savePreferencesEnabled,
        canSaveInstructions: settings.saveInstructionsEnabled,
        canSaveApprovalModes: settings.saveDirectApprovalEnabled
          && settings.saveTaskStartApprovalEnabled,
        canChangeService: true,
        servicePlatform: "Windows",
        serviceDescription: "Windows 用户登录自动启动后台 Service，退出窗口后继续运行。",
        statusMessage: settings.statusText,
        modelCount: settings.modelOptions.count,
        canRefreshModels: canRefreshModels && !settings.isRefreshingModels,
        isRefreshingModels: settings.isRefreshingModels,
        modelError: settings.modelError
      )
    }

    private static func effortChoice(
      _ value: String,
      includesDefault: Bool = false
    ) -> BridgeDesktopChoice {
      choice(
        value,
        BridgeDesktopPresentation.extendedReasoningTitle(value),
        enabled: includesDefault || !value.isEmpty
      )
    }

    private static func accessChoice(_ value: String) -> BridgeDesktopChoice {
      choice(value, BridgeDesktopPresentation.accessModeTitle(value))
    }

    private static func approvalChoice(_ value: String) -> BridgeDesktopChoice {
      choice(value, BridgeDesktopPresentation.approvalModeTitle(value))
    }
  }
#endif
