import BridgeDesktopUI
import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore

extension BridgeDesktopUIStateBuilder {
  static func settings(from model: BridgeServiceAppModel) -> BridgeDesktopSettingsState {
    let preferences = model.modelPreferences
    let models = model.models.map(modelOption)
    let executionModel = preferences?.executionModel ?? ""
    let service = servicePresentation(
      status: model.registrationStatus,
      keepServiceRunningAfterExit: model.keepServiceRunningAfterAppExit
    )
    return BridgeDesktopSettingsState(
      header: BridgeDesktopPageHeader(
        title: "设置",
        subtitle: "配置 Agent模型与权限、安全审批与 macOS 后台服务。",
        symbol: BridgeServiceNavigation.settings.symbol
      ),
      models: models,
      executionModel: executionModel,
      executionEffort: preferences?.executionEffort ?? "",
      effortOptions: effortOptions(for: executionModel, models: model.models),
      accessMode: preferences?.accessMode ?? "request-approval",
      accessOptions: accessOptions,
      fastModeEnabled: preferences?.fastModeEnabled ?? false,
      directApprovalMode: model.directApprovalMode,
      directApprovalOptions: modeOptions(
        current: model.directApprovalMode,
        values: ["require", "auto"],
        titles: ["require": "每次需要批准", "auto": "自动批准"]
      ),
      taskStartApprovalMode: model.taskStartApprovalMode,
      taskStartApprovalOptions: modeOptions(
        current: model.taskStartApprovalMode,
        values: ["require", "auto"],
        titles: ["require": "每次需要批准", "auto": "自动批准"]
      ),
      customInstructions: model.customInstructions ?? "",
      agentDefaults: agentDefaults(from: model),
      nativePermissionPolicy: nativePermissionPolicy(from: model),
      keepServiceRunningAfterExit: model.keepServiceRunningAfterAppExit,
      serviceRegistered: model.registrationStatus == .enabled,
      canSavePreferences: preferences != nil && !model.models.isEmpty
        && model.connectionState == .connected,
      canSaveInstructions: model.connectionState == .connected,
      canSaveApprovalModes: model.connectionState == .connected,
      canChangeService: false,
      servicePlatform: "macOS",
      serviceDescription: "开启后可在退出 App 后继续运行后台 Service，远程给本机发送任务时需同时将“远程任务启动”设为“自动批准”。",
      serviceStatus: service.status,
      serviceStatusTitle: service.title,
      serviceStatusMessage: service.message,
      serviceStatusTone: service.tone,
      serviceActions: service.actions,
      statusMessage: model.modelCatalogError ?? model.errorMessage,
      modelCount: model.models.count,
      canRefreshModels: !model.isRefreshing,
      isRefreshingModels: model.isRefreshing,
      modelError: model.modelCatalogError,
      direct: model.directConfiguration.map {
        BridgeDesktopDirectState(
          commandMode: $0.commandMode, allowedCommands: $0.allowedCommands,
          deniedCommands: $0.deniedCommands, usesProjectDefaults: $0.usesProjectDefaults == true,
          canSave: model.connectionState == .connected && !model.isSavingDirectConfiguration)
      }
    )
  }

  private static let accessOptions = [
    BridgeDesktopChoice(
      id: "request-approval",
      title: "请求批准",
      detail: "编辑文件或使用外部工具时询问本机批准"
    ),
    BridgeDesktopChoice(id: "auto-review", title: "自动评审"),
    BridgeDesktopChoice(id: "full-access", title: "完全访问权限"),
  ]

  private static func modelOption(_ model: MCPModelSummary) -> BridgeDesktopModelOption {
    BridgeDesktopModelOption(
      modelID: model.modelID,
      displayName: model.displayName,
      reasoningEfforts: model.reasoningEfforts.map {
        BridgeDesktopChoice(id: $0, title: reasoningTitle($0))
      },
      defaultReasoningEffort: model.defaultReasoningEffort,
      supportsFastMode: model.supportsFastMode
    )
  }

  private static func effortOptions(
    for modelID: String,
    models: [MCPModelSummary]
  ) -> [BridgeDesktopChoice] {
    models.first(where: { $0.modelID == modelID })?.reasoningEfforts.map {
      BridgeDesktopChoice(id: $0, title: reasoningTitle($0))
    } ?? []
  }

  private static func modeOptions(
    current: String,
    values: [String],
    titles: [String: String]
  ) -> [BridgeDesktopChoice] {
    var result = values.map { BridgeDesktopChoice(id: $0, title: titles[$0] ?? $0) }
    if !current.isEmpty && !values.contains(current) {
      result.insert(BridgeDesktopChoice(id: current, title: "当前设置 · \(current)"), at: 0)
    }
    return result
  }

  private static func agentDefaults(
    from model: BridgeServiceAppModel
  ) -> [BridgeDesktopAgentDefaultState] {
    model.agentProviders.map { provider in
      let installation = model.agentInstallations.first {
        $0.providerID == provider.providerID && $0.isEnabled && $0.availability == "available"
      }
      let defaultValue = model.agentModelDefault(for: provider.providerID)
      let options = model.agentModelOptions(for: provider.providerID)
      let selected = model.agentSelectedModel(for: provider.providerID)
      let modelOptions = options.map { item in
        BridgeDesktopModelOption(
          modelID: item.modelID,
          displayName: item.displayName,
          reasoningEfforts: item.supportedReasoningEfforts.map {
            BridgeDesktopChoice(id: $0, title: BridgeDesktopPresentation.reasoningTitle($0))
          },
          defaultReasoningEffort: item.defaultReasoningEffort,
          reasoningCapabilitiesAvailable: item.reasoningCapabilitiesAvailable,
          isDefaultModel: item.isDefaultModel
        )
      }
      return BridgeDesktopAgentDefaultState(
        providerID: provider.providerID,
        providerName: provider.displayName,
        installationID: installation?.installationID,
        installationName: installation?.displayName,
        model: defaultValue.model,
        modelOptions: modelOptions,
        effort: defaultValue.effort,
        effortOptions: selected?.supportedReasoningEfforts.map {
          BridgeDesktopChoice(id: $0, title: BridgeDesktopPresentation.reasoningTitle($0))
        } ?? [],
        permissionMode: defaultValue.permissionMode,
        permissionOptions: BridgeDesktopPresentation.agentPermissionOptions(
          for: provider.providerID
        ),
        canSave: model.connectionState == .connected,
        canRefreshModels: provider.supportsModelSelection
          && installation?.effectiveCapabilities.contains("selection.model") == true,
        isRefreshingModels: model.isRefreshingAgentModels(for: provider.providerID),
        errorMessage: model.agentModelRefreshError(for: provider.providerID) ?? model.errorMessage,
        canSelectModel: provider.supportsModelSelection
          && installation?.effectiveCapabilities.contains("selection.model") == true,
        canSelectEffort: provider.supportsEffortSelection && installation != nil
      )
    }
  }

  private static func nativePermissionPolicy(
    from model: BridgeServiceAppModel
  ) -> BridgeDesktopNativePermissionState? {
    let providers: Set<String> = ["antigravity", "pi", "qoder"]
    let installations = model.agentInstallations.filter {
      providers.contains($0.providerID) && $0.isEnabled && $0.availability == "available"
    }
    guard !installations.isEmpty else { return nil }
    let installation =
      model.focusedAgentNativePermissionInstallationID.flatMap { focused in
        installations.first(where: { $0.installationID == focused })
      } ?? installations[0]
    let snapshot = model.nativePermissionPolicy(installationID: installation.installationID)
    let isLoading = model.isLoadingNativePermissionPolicy(installation.installationID)
    let isSaving = model.isSavingNativePermissionPolicy(installation.installationID)
    return BridgeDesktopNativePermissionState(
      providerID: installation.providerID,
      providerName: model.agentProviders.first(where: { $0.providerID == installation.providerID })?
        .displayName ?? installation.providerID,
      installationID: installation.installationID,
      installationName: installation.displayName,
      installations: installations.map {
        BridgeDesktopChoice(id: $0.installationID, title: $0.displayName)
      },
      toolPermission: snapshot?.toolPermission,
      availableModes: snapshot?.availableModes.map {
        BridgeDesktopNativePermissionMode(
          modeID: $0.modeID,
          displayName: $0.displayName,
          requiresConfirmation: $0.requiresConfirmation
        )
      } ?? [],
      availableActions: snapshot?.availableActions ?? [],
      rules: snapshot?.rules.map {
        BridgeDesktopNativePermissionRule(
          ruleID: $0.ruleID,
          effect: $0.effect,
          action: $0.action,
          target: $0.target,
          isEditable: $0.isEditable,
          isRedacted: $0.isRedacted,
          requiresConfirmation: $0.requiresConfirmation
        )
      } ?? [],
      warnings: snapshot?.warnings ?? [],
      isLoading: isLoading,
      isSaving: isSaving,
      canEdit: model.connectionState == .connected && snapshot != nil && !isLoading && !isSaving,
      errorMessage: model.agentNativePermissionErrors[installation.installationID]
    )
  }

  private static func reasoningTitle(_ effort: String) -> String {
    BridgeDesktopPresentation.reasoningTitle(effort)
  }
}
