#if os(Windows)
  import BridgeDesktopUI

  extension WindowsDesktopUIStateBuilder {
    static func settingsPage(
      settings: WindowsSettingsDisplay?,
      agentDefaults: WindowsAgentDefaultsDisplay?
    ) -> BridgeDesktopSettingsState? {
      guard let settings else { return nil }
      let canRefreshModels = !settings.busy
      let service = servicePresentation(registered: settings.serviceRegistered)
      return BridgeDesktopSettingsState(
        header: header(
          "设置",
          "配置模型、执行偏好、安全策略与全局指令。",
          "gearshape"
        ),
        models: settings.modelOptions,
        executionModel: settings.executionModel,
        executionEffort: settings.executionEffort,
        effortOptions: effortOptions(
          for: settings.executionModel,
          models: settings.modelOptions
        ),
        accessMode: settings.accessMode,
        accessOptions: settings.accessValues.map { accessChoice($0) },
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
        canChangeService: false,
        servicePlatform: "Windows",
        serviceDescription: "开启后可在退出窗口后继续运行后台 Service，远程给本机发送任务时需同时将“远程任务启动”设为“自动批准”。",
        serviceStatus: service.status,
        serviceStatusTitle: service.title,
        serviceStatusMessage: service.message,
        serviceStatusTone: service.tone,
        serviceActions: service.actions,
        statusMessage: settings.statusText,
        modelCount: settings.modelOptions.count,
        canRefreshModels: canRefreshModels && !settings.isRefreshingModels,
        isRefreshingModels: settings.isRefreshingModels,
        modelError: settings.modelError,
        direct: settings.direct
      )
    }

    private static func servicePresentation(
      registered: Bool
    ) -> (
      status: String,
      title: String,
      message: String,
      tone: BridgeDesktopStatusTone,
      actions: [BridgeDesktopActionLink]
    ) {
      if registered {
        return (
          "enabled",
          "已启用",
          "Windows 用户登录后自动启动后台 Service。",
          .success,
          []
        )
      }
      return (
        "not_registered",
        "未注册",
        "下次启动时会自动注册后台 Service。",
        .warning,
        []
      )
    }

    private static func effortOptions(
      for modelID: String,
      models: [BridgeDesktopModelOption]
    ) -> [BridgeDesktopChoice] {
      models.first(where: { $0.modelID == modelID })?.reasoningEfforts ?? []
    }

    private static func accessChoice(_ value: String) -> BridgeDesktopChoice {
      choice(value, BridgeDesktopPresentation.accessModeTitle(value))
    }

    private static func approvalChoice(_ value: String) -> BridgeDesktopChoice {
      choice(value, BridgeDesktopPresentation.approvalModeTitle(value))
    }
  }
#endif
