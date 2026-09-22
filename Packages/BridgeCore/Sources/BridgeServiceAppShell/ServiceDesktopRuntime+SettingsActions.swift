import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore

extension BridgeServiceAppModel {
  func setTaskStartApprovalMode(_ mode: String) {
    guard mode == "require" || mode == "auto" else { return }
    runMutation { [weak self] client in
      try await client.setTaskStartApprovalMode(mode)
      self?.taskStartApprovalMode = mode
      self?.postToast(
        mode == "auto"
          ? "远程 Agent 启动请求将自动批准"
          : "远程 Agent 启动请求恢复为本机批准"
      )
    }
  }

  func saveCustomInstructions(_ instructions: String) {
    guard !isSavingCustomInstructions else { return }
    isSavingCustomInstructions = true
    errorMessage = nil
    Task { [weak self] in
      guard let self else { return }
      defer { self.isSavingCustomInstructions = false }
      do {
        try await self.currentClient().setCustomInstructions(instructions)
        self.customInstructions = instructions
        self.postToast("全局自定义指令已保存；Qwen 重连后应用，ChatGPT 请刷新插件并在新对话中重新添加")
      } catch {
        self.errorMessage = Self.message(error)
      }
    }
  }

  public func setDirectApprovalMode(_ mode: String) {
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.setDirectApprovalMode(mode)
      await self.refresh(silent: true, includeCatalog: false)
      self.postToast(mode == "auto" ? "已开启 Direct 操作自动批准" : "已设置为每次 Direct 操作均需批准")
    }
  }

  public func setExposureMode(_ mode: MCPServiceExposureMode) {
    updateExposureState(mode)
    runMutation { [weak self] client in
      guard let self else { return }
      try await client.setExposureMode(mode)
      await self.refresh(silent: true, includeCatalog: false)
      self.postToast("MCP 工具权限已更新为：\(mode.localizedTitle)")
    }
  }

  /// Applies a user-configured Codex executable; an empty path restores discovery.
  func setCodexExecutablePath(_ path: String?) {
    let configured = (path?.isEmpty ?? true) ? nil : path
    runMutation { [weak self] client in
      guard let self else { return }
      self.serviceStatus = try await client.setCodexExecutablePath(configured)
      await self.refresh(silent: true, includeCatalog: true, forceCatalogRefresh: true)
      self.postToast(configured == nil ? "Codex 已恢复自动发现" : "Codex 可执行文件已更新")
    }
  }

  func setModelPreferences(_ preferences: IPCModelPreferences) {
    let previous = modelPreferences
    modelPreferences = preferences
    runMutation { [weak self] client in
      guard let self else { return }
      do {
        try await client.setModelPreferences(preferences)
        await self.refresh(silent: true, includeCatalog: true)
        self.postToast("模型偏好设置已更新")
      } catch {
        modelPreferences = previous
        throw error
      }
    }
  }

  func setExecutionModel(_ modelID: String) {
    guard let current = modelPreferences,
      let model = models.first(where: { $0.modelID == modelID })
    else { return }

    let effort =
      model.reasoningEfforts.contains(current.executionEffort)
      ? current.executionEffort
      : model.defaultReasoningEffort ?? model.reasoningEfforts[0]

    setModelPreferences(
      IPCModelPreferences(
        executionModel: modelID,
        executionEffort: effort,
        supervisorModel: current.supervisorModel,
        supervisorEffort: current.supervisorEffort,
        supervisorEnabled: current.supervisorEnabled,
        accessMode: current.accessMode,
        fastModeEnabled: current.fastModeEnabled
      )
    )
  }

  func setExecutionEffort(_ effort: String) {
    guard let current = modelPreferences,
      let model = models.first(where: { $0.modelID == current.executionModel }),
      model.reasoningEfforts.contains(effort)
    else { return }
    setModelPreferences(
      IPCModelPreferences(
        executionModel: current.executionModel,
        executionEffort: effort,
        supervisorModel: current.supervisorModel,
        supervisorEffort: current.supervisorEffort,
        supervisorEnabled: current.supervisorEnabled,
        accessMode: current.accessMode,
        fastModeEnabled: current.fastModeEnabled
      )
    )
  }

  func setAccessMode(_ mode: String) {
    guard let current = modelPreferences else { return }
    setModelPreferences(
      IPCModelPreferences(
        executionModel: current.executionModel,
        executionEffort: current.executionEffort,
        supervisorModel: current.supervisorModel,
        supervisorEffort: current.supervisorEffort,
        supervisorEnabled: current.supervisorEnabled,
        accessMode: mode,
        fastModeEnabled: current.fastModeEnabled
      )
    )
  }

  func setFastMode(_ enabled: Bool) {
    guard let current = modelPreferences else { return }
    setModelPreferences(
      IPCModelPreferences(
        executionModel: current.executionModel,
        executionEffort: current.executionEffort,
        supervisorModel: current.supervisorModel,
        supervisorEffort: current.supervisorEffort,
        supervisorEnabled: current.supervisorEnabled,
        accessMode: current.accessMode,
        fastModeEnabled: enabled
      )
    )
  }

}

extension MCPServiceExposureMode {
  public var localizedTitle: String {
    switch self {
    case .readOnly: "只读模式"
    case .full: "完整操作"
    }
  }
}
