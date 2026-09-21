import BridgeDesktopUI
import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore

extension BridgeDesktopCommandRouter {
  static func handleSettings(
    _ envelope: BridgeDesktopCommandEnvelope,
    model: BridgeServiceAppModel
  ) {
    let payload = envelope.payload
    switch envelope.command {
    case .saveAgentDefault:
      saveAgentDefault(payload, model: model)
    case .setExecutionModel:
      guard connected(model), let modelID = modelID(payload.modelID, in: model.models) else {
        return
      }
      model.setExecutionModel(modelID)
    case .setExecutionEffort:
      guard connected(model), let preferences = model.modelPreferences,
        let effort = effort(payload.effort, for: preferences.executionModel, in: model.models)
      else { return }
      model.setExecutionEffort(effort)
    case .setAccessMode:
      guard connected(model), let mode = accessMode(payload.accessMode) else { return }
      model.setAccessMode(mode)
    case .setFastMode:
      guard connected(model), let enabled = payload.fastModeEnabled else { return }
      if enabled {
        guard let current = model.modelPreferences,
          model.models.first(where: { $0.modelID == current.executionModel })?.supportsFastMode
            == true
        else { return }
      }
      model.setFastMode(enabled)
    case .setDirectApprovalMode:
      guard connected(model), let mode = approvalMode(payload.mode) else { return }
      model.setDirectApprovalMode(mode)
    case .setTaskStartApprovalMode:
      guard connected(model), let mode = approvalMode(payload.mode) else { return }
      model.setTaskStartApprovalMode(mode)
    case .saveSettings:
      saveSettings(payload, model: model)
    case .saveCustomInstructions:
      guard connected(model),
        let instructions = validatedText(
          payload.input ?? payload.value,
          maximumBytes: 32 * 1_024
        )
      else { return }
      model.saveCustomInstructions(instructions)
    case .registerService:
      model.registerService()
    case .unregisterService:
      model.unregisterService()
    case .setKeepServiceRunning:
      guard let keep = payload.keepServiceRunningAfterExit else { return }
      model.keepServiceRunningAfterAppExit = keep
    case .updateBrowserViewport:
      updateBrowserViewport(payload.viewport, model: model)
    default:
      return
    }
  }

  private static func saveAgentDefault(
    _ payload: BridgeDesktopCommandPayload,
    model: BridgeServiceAppModel
  ) {
    guard connected(model), let providerID = validatedID(payload.providerID, maximumBytes: 128),
      let provider = model.agentProviders.first(where: { $0.providerID == providerID })
    else { return }
    if let installationID = validatedID(payload.installationID, maximumBytes: 256),
      !model.agentInstallations.contains(where: {
        $0.installationID == installationID
          && $0.providerID == providerID
      })
    {
      return
    }
    let selectedModel = payload.modelID.flatMap { validatedID($0, maximumBytes: 512) }
    if let selectedModel {
      guard provider.supportsModelSelection,
        model.agentModelOptions(for: providerID).contains(where: { $0.modelID == selectedModel })
      else { return }
    }
    let current = model.agentModelDefault(for: providerID)
    let options = model.agentModelOptions(for: providerID)
    let effectiveModel = AgentModelCatalogResolver.modelForSelection(
      modelID: selectedModel, models: options)?.modelID
    let selectedEffort = payload.effort.flatMap { validatedID($0, maximumBytes: 64) }
    if let selectedEffort {
      guard provider.supportsEffortSelection,
        let selected = model.agentModelOptions(for: providerID).first(where: {
          $0.modelID == effectiveModel
        }),
        selected.supportedReasoningEfforts.contains(selectedEffort)
      else { return }
    }
    let permission = validatedAgentPermission(
      payload.permissionMode ?? current.permissionMode,
      providerID: providerID
    )
    guard let permission else { return }
    model.saveAgentDefaults(
      providerID: providerID, model: selectedModel, permissionMode: permission,
      effort: selectedEffort)
    if selectedModel != current.model,
      options.first(where: { $0.modelID == effectiveModel })?.reasoningCapabilitiesAvailable
        == false
    {
      let installationID =
        payload.installationID
        ?? model.agentInstallations.first {
          $0.providerID == providerID && $0.isEnabled && $0.availability == "available"
        }?.installationID
      model.refreshAgentModelCatalog(
        installationID: installationID, providerID: providerID, forceRefresh: false)
    }
  }

  private static func validatedAgentPermission(
    _ value: String,
    providerID: String
  ) -> String? {
    let writable = providerID == "opencode" ? "build" : "workspace-write"
    let readOnly = providerID == "opencode" || providerID == "antigravity" ? "plan" : "read-only"
    return value == writable || value == readOnly ? value : nil
  }

  private static func saveSettings(
    _ payload: BridgeDesktopCommandPayload,
    model: BridgeServiceAppModel
  ) {
    guard connected(model), let current = model.modelPreferences else { return }
    let executionModel =
      payload.executionModel.flatMap { modelID($0, in: model.models) }
      ?? current.executionModel
    guard model.models.contains(where: { $0.modelID == executionModel }) else { return }
    let executionEffort =
      payload.executionEffort.flatMap {
        effort($0, for: executionModel, in: model.models)
      } ?? current.executionEffort
    guard
      model.models.first(where: { $0.modelID == executionModel })?.reasoningEfforts
        .contains(executionEffort) == true,
      accessMode(payload.accessMode ?? current.accessMode) != nil
    else { return }
    let fastModeEnabled = payload.fastModeEnabled ?? current.fastModeEnabled
    if fastModeEnabled,
      model.models.first(where: { $0.modelID == executionModel })?.supportsFastMode != true
    {
      return
    }
    model.setModelPreferences(
      IPCModelPreferences(
        executionModel: executionModel,
        executionEffort: executionEffort,
        supervisorModel: current.supervisorModel,
        supervisorEffort: current.supervisorEffort,
        supervisorEnabled: current.supervisorEnabled,
        accessMode: payload.accessMode ?? current.accessMode,
        fastModeEnabled: fastModeEnabled
      )
    )
  }

  private static func modelID(
    _ value: String?,
    in models: [MCPModelSummary]
  ) -> String? {
    guard let value = validatedID(value, maximumBytes: 512),
      models.contains(where: { $0.modelID == value })
    else { return nil }
    return value
  }

  private static func effort(
    _ value: String?,
    for modelID: String,
    in models: [MCPModelSummary]
  ) -> String? {
    guard let value = validatedID(value, maximumBytes: 64),
      models.first(where: { $0.modelID == modelID })?.reasoningEfforts.contains(value) == true
    else { return nil }
    return value
  }

  private static func accessMode(_ value: String?) -> String? {
    guard let value = validatedID(value, maximumBytes: 64),
      ["request-approval", "auto-review", "full-access"].contains(value)
    else { return nil }
    return value
  }

  private static func approvalMode(_ value: String?) -> String? {
    guard let value = validatedID(value, maximumBytes: 32), value == "require" || value == "auto"
    else { return nil }
    return value
  }

  private static func updateBrowserViewport(
    _ viewport: BridgeDesktopBrowserViewport?,
    model: BridgeServiceAppModel
  ) {
    guard model.navigation == .workbench, model.isChatBrowserEnabled, let viewport,
      viewport.x.isFinite, viewport.y.isFinite, viewport.width.isFinite,
      viewport.height.isFinite,
      viewport.x >= 0, viewport.y >= 0, viewport.width >= 0, viewport.height >= 0,
      viewport.width <= 16_384, viewport.height <= 16_384
    else {
      model.chatBrowserViewport = nil
      return
    }
    model.chatBrowserViewport = viewport
  }
}
