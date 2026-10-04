#if os(Windows) || os(Linux)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeMCP

  import BridgeServiceAppCore

  typealias WindowsSettingsPatchError = CodexPreferencesPatchError

  extension WindowsSettingsModel {
    func applyPreferencesPatch(_ patch: BridgeDesktopSettingsPatch) async {
      guard connectionState == .connected,
        let current = preferenceQueue.editingValue(confirmed: preferences)
      else { return }
      do {
        let next = try Self.patchedPreferences(
          current: current,
          models: models,
          patch: patch
        )
        await savePreferences(next)
      } catch let error as WindowsSettingsPatchError {
        rejectPreferencesPatch(error.message)
      } catch {
        rejectPreferencesPatch("模型设置不可用。")
      }
    }

    nonisolated static func patchedPreferences(
      current: IPCModelPreferences,
      models: [MCPModelSummary],
      patch: BridgeDesktopSettingsPatch
    ) throws -> IPCModelPreferences {
      try CodexPreferencesPatch.apply(
        to: current, models: models, executionModel: patch.executionModel,
        executionEffort: patch.executionEffort, accessMode: patch.accessMode,
        fastModeEnabled: patch.fastModeEnabled)
    }

    private func rejectPreferencesPatch(_ message: String) {
      statusText = message
      feedback.postAlert(message, title: "模型设置无法保存")
      refreshDisplaySnapshot()
    }
  }
#endif
