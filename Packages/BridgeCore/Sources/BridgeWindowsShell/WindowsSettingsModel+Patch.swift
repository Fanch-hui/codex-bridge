#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeMCP

  enum WindowsSettingsPatchError: Error, Equatable {
    case executionModelUnavailable
    case executionEffortUnavailable
    case executionEffortMissing
    case accessModeUnavailable
    case fastModeUnavailable

    var message: String {
      switch self {
      case .executionModelUnavailable: "执行模型不可用。"
      case .executionEffortUnavailable: "执行推理强度不受当前模型支持。"
      case .executionEffortMissing: "执行模型没有可用的推理强度。"
      case .accessModeUnavailable: "访问模式不可用。"
      case .fastModeUnavailable: "当前执行模型不支持快速模式。"
      }
    }
  }

  extension WindowsSettingsModel {
    func applyPreferencesPatch(_ patch: BridgeDesktopSettingsPatch) async {
      guard connectionState == .connected, !busy, let current = preferences else { return }
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
      let executionModelID = patch.executionModel ?? current.executionModel
      guard let executionModel = models.first(where: { $0.modelID == executionModelID }) else {
        throw WindowsSettingsPatchError.executionModelUnavailable
      }

      let executionEffort: String
      if let requestedEffort = patch.executionEffort {
        guard executionModel.reasoningEfforts.contains(requestedEffort) else {
          throw WindowsSettingsPatchError.executionEffortUnavailable
        }
        executionEffort = requestedEffort
      } else if executionModel.reasoningEfforts.contains(current.executionEffort) {
        executionEffort = current.executionEffort
      } else if let fallback = executionModel.defaultReasoningEffort
        ?? executionModel.reasoningEfforts.first
      {
        executionEffort = fallback
      } else {
        throw WindowsSettingsPatchError.executionEffortMissing
      }

      let accessMode = patch.accessMode ?? current.accessMode
      guard accessValues.contains(accessMode) else {
        throw WindowsSettingsPatchError.accessModeUnavailable
      }
      let fastModeEnabled = patch.fastModeEnabled ?? current.fastModeEnabled
      guard !fastModeEnabled || executionModel.supportsFastMode else {
        throw WindowsSettingsPatchError.fastModeUnavailable
      }

      return IPCModelPreferences(
        executionModel: executionModelID,
        executionEffort: executionEffort,
        supervisorModel: current.supervisorModel,
        supervisorEffort: current.supervisorEffort,
        supervisorEnabled: false,
        accessMode: accessMode,
        fastModeEnabled: fastModeEnabled
      )
    }

    private func rejectPreferencesPatch(_ message: String) {
      statusText = message
      feedback.postAlert(message, title: "模型设置无法保存")
      refreshDisplaySnapshot()
    }
  }
#endif
