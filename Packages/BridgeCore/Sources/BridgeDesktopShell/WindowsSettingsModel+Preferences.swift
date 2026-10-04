#if os(Windows) || os(Linux)
  import BridgeIPC
  import BridgeServiceAppCore

  extension WindowsSettingsModel {
    func savePreferences(_ value: IPCModelPreferences) async {
      guard connectionState == .connected else { return }
      let normalized = IPCModelPreferences(
        executionModel: value.executionModel, executionEffort: value.executionEffort,
        supervisorModel: value.supervisorModel, supervisorEffort: value.supervisorEffort,
        supervisorEnabled: false, accessMode: value.accessMode,
        fastModeEnabled: value.fastModeEnabled)
      preferenceQueue.enqueue(normalized)
      guard preferenceQueue.active == nil else { return }
      modelCatalogGeneration &+= 1
      statusText = "正在保存模型设置…"
      publishDisplay()
      defer {
        modelCatalogGeneration &+= 1
        publishDisplay()
      }
      while let next = preferenceQueue.beginNext() {
        do {
          try await client.setModelPreferences(next)
          preferences = next
          statusText = "模型设置已保存。"
        } catch {
          statusText = "模型设置保存失败：\(BridgeServiceErrorMessage.message(error))"
          feedback.postAlert(statusText)
        }
        preferenceQueue.finish()
      }
      if statusText == "模型设置已保存。" { feedback.postToast(statusText) }
    }
  }
#endif
