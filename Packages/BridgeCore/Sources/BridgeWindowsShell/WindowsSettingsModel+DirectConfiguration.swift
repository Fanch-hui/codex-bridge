#if os(Windows)
  import BridgeIPC
  import Foundation

  extension WindowsSettingsModel {
    func saveDirectConfiguration(_ json: String) async {
      guard !busy, connectionState == .connected else { return }
      busy = true
      publishDisplay()
      defer {
        busy = false
        publishDisplay()
      }
      do {
        let value = try JSONDecoder().decode(IPCDirectConfiguration.self, from: Data(json.utf8))
        directConfiguration = try await client.updateDirectConfiguration(value)
        statusText = "Direct 命令规则已应用到所有项目。"
      } catch { statusText = "保存 Direct 规则失败：\(error.localizedDescription)" }
    }
  }
#endif
