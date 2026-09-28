#if os(Windows)
  import BridgeDesktopUI

  extension CodexBridgeWindowsApplication {
    static func runDesktopSettingsCommand(
      _ envelope: BridgeDesktopCommandEnvelope,
      auxiliary: WindowsAuxiliaryRuntime
    ) -> Bool {
      let payload = envelope.payload
      switch envelope.command {
      case .saveDirectConfiguration:
        guard let value = payload.value else { return true }
        Task { @MainActor in await auxiliary.settings.saveDirectConfiguration(value) }
      case .setDirectApprovalMode:
        guard let mode = BridgeDesktopCommandValue.nonEmpty(payload.mode) else { return true }
        Task { @MainActor in await auxiliary.settings.setDirectApprovalMode(mode) }
      case .setTaskStartApprovalMode:
        guard let mode = BridgeDesktopCommandValue.nonEmpty(payload.mode) else { return true }
        Task { @MainActor in await auxiliary.settings.setTaskStartApprovalMode(mode) }
      case .saveSettings:
        guard let executionModel = BridgeDesktopCommandValue.nonEmpty(payload.executionModel),
          let executionEffort = payload.executionEffort,
          let accessMode = BridgeDesktopCommandValue.nonEmpty(payload.accessMode)
        else { return true }
        let patch = BridgeDesktopSettingsPatch(
          executionModel: executionModel,
          executionEffort: executionEffort,
          accessMode: accessMode,
          fastModeEnabled: payload.fastModeEnabled ?? false
        )
        Task { @MainActor in await auxiliary.settings.applyPreferencesPatch(patch) }
      case .saveCustomInstructions:
        let text = payload.value ?? payload.input ?? ""
        Task { @MainActor in await auxiliary.settings.saveInstructions(text) }
      case .setExecutionModel:
        guard
          let value = BridgeDesktopCommandValue.nonEmpty(payload.modelID ?? payload.executionModel)
        else { return true }
        let patch = BridgeDesktopSettingsPatch(executionModel: value)
        Task { @MainActor in await auxiliary.settings.applyPreferencesPatch(patch) }
      case .setExecutionEffort:
        guard
          let value = BridgeDesktopCommandValue.nonEmpty(payload.effort ?? payload.executionEffort)
        else { return true }
        let patch = BridgeDesktopSettingsPatch(executionEffort: value)
        Task { @MainActor in await auxiliary.settings.applyPreferencesPatch(patch) }
      case .setAccessMode:
        guard let value = BridgeDesktopCommandValue.nonEmpty(payload.accessMode) else {
          return true
        }
        let patch = BridgeDesktopSettingsPatch(accessMode: value)
        Task { @MainActor in await auxiliary.settings.applyPreferencesPatch(patch) }
      case .setFastMode:
        guard let enabled = payload.fastModeEnabled ?? payload.enabled else { return true }
        let patch = BridgeDesktopSettingsPatch(fastModeEnabled: enabled)
        Task { @MainActor in await auxiliary.settings.applyPreferencesPatch(patch) }
      case .registerService:
        Task { @MainActor in await auxiliary.settings.registerService() }
      case .unregisterService:
        Task { @MainActor in await auxiliary.settings.unregisterService() }
      case .setKeepServiceRunning:
        auxiliary.settings.setKeepServiceRunningAfterExit(
          payload.keepServiceRunningAfterExit ?? true)
      default:
        return false
      }
      return true
    }

    static func runDesktopLogCommand(
      _ envelope: BridgeDesktopCommandEnvelope,
      auxiliary: WindowsAuxiliaryRuntime
    ) -> Bool {
      let payload = envelope.payload
      switch envelope.command {
      case .selectLog:
        guard let logID = BridgeDesktopCommandValue.nonEmpty(payload.logID) else { return true }
        let taskID = BridgeDesktopCommandValue.nonEmpty(payload.taskID)
        guard
          let index = auxiliary.logs.displayBox.current().rowsTyped.firstIndex(where: {
            $0.id == logID && (taskID == nil || $0.taskID == taskID)
          })
        else { return true }
        auxiliary.logs.selectItem(at: index)
      case .refreshLogs:
        Task { @MainActor in await auxiliary.logs.refresh() }
      case .setLogSearch:
        auxiliary.logs.setSearchText(payload.searchText ?? "")
      case .setLogProjectFilter:
        let target = BridgeDesktopCommandValue.nonEmpty(payload.projectID) ?? "all"
        let display = auxiliary.logs.displayBox.current()
        guard let index = display.projectOptions.firstIndex(where: { $0.id == target }) else {
          return true
        }
        auxiliary.logs.setProjectFilter(index)
      case .setLogKindFilter:
        guard let kind = BridgeDesktopCommandValue.nonEmpty(payload.kind),
          ["all", "command", "file", "other"].contains(kind),
          let index = ["all", "command", "file", "other"].firstIndex(of: kind)
        else { return true }
        auxiliary.logs.setKindFilter(index)
      case .copyLogs:
        let display = auxiliary.logs.displayBox.current()
        auxiliary.logs.didCopy(
          WindowsClipboard.write(display.copyText, owner: WindowsMainWindow.currentWindow()))
      default:
        return false
      }
      return true
    }
  }
#endif
