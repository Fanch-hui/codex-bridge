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

  func setExecutionModel(_ modelID: String) {
    applyModelPreferencesPatch(executionModel: modelID)
  }

  func setExecutionEffort(_ effort: String) {
    applyModelPreferencesPatch(executionEffort: effort)
  }

  func setAccessMode(_ mode: String) {
    applyModelPreferencesPatch(accessMode: mode)
  }

  func setFastMode(_ enabled: Bool) {
    applyModelPreferencesPatch(fastModeEnabled: enabled)
  }

  func applyModelPreferencesPatch(
    executionModel: String? = nil, executionEffort: String? = nil,
    accessMode: String? = nil, fastModeEnabled: Bool? = nil
  ) {
    guard
      let current = codexModelCatalogRequests.preferenceQueue.editingValue(
        confirmed: modelPreferences)
    else { return }
    do {
      setModelPreferences(
        try CodexPreferencesPatch.apply(
          to: current, models: models, executionModel: executionModel,
          executionEffort: executionEffort, accessMode: accessMode, fastModeEnabled: fastModeEnabled
        ))
    } catch let error as CodexPreferencesPatchError {
      errorMessage = error.message
    } catch {
      errorMessage = Self.message(error)
    }
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
