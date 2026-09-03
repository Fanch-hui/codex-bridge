import BridgeDesktopUI
import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore

extension BridgeDesktopUIStateBuilder {
  static func settings(from model: BridgeServiceAppModel) -> BridgeDesktopSettingsState {
    let preferences = model.modelPreferences
    let models = model.models.map(modelOption)
    let executionModel = preferences?.executionModel ?? ""
    let supervisorModel = preferences?.supervisorModel ?? ""
    return BridgeDesktopSettingsState(
      header: BridgeDesktopPageHeader(
        title: "设置",
        subtitle: "配置模型、安全审批、外部 Agent 默认偏好与 macOS 后台服务。",
        symbol: BridgeServiceNavigation.settings.symbol
      ),
      models: models,
      executionModel: executionModel,
      executionEffort: preferences?.executionEffort ?? "",
      supervisorModel: supervisorModel,
      supervisorEffort: preferences?.supervisorEffort ?? "",
      supervisorAvailable: true,
      effortOptions: effortOptions(for: executionModel, models: model.models),
      supervisorEffortOptions: effortOptions(for: supervisorModel, models: model.models),
      accessMode: preferences?.accessMode ?? "request-approval",
      accessOptions: accessOptions,
      supervisorEnabled: preferences?.supervisorEnabled ?? true,
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
      keepServiceRunningAfterExit: model.keepServiceRunningAfterAppExit,
      serviceRegistered: model.registrationStatus == .enabled,
      canSavePreferences: preferences != nil && !model.models.isEmpty
        && model.connectionState == .connected,
      canSaveInstructions: model.connectionState == .connected,
      canSaveApprovalModes: model.connectionState == .connected,
      canChangeService: true,
      servicePlatform: "macOS",
      serviceDescription: "LaunchAgent 后台 Service 可在 App 退出后继续提供本机 MCP 服务。",
      statusMessage: model.modelCatalogError ?? model.errorMessage
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
      }
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
          }
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
        errorMessage: model.agentModelRefreshError(for: provider.providerID)
      )
    }
  }

  private static func reasoningTitle(_ effort: String) -> String {
    BridgeDesktopPresentation.reasoningTitle(effort)
  }
}
