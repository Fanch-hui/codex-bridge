import BridgeIPC
import Foundation

extension BridgeServiceAppModel {
  func saveDirectConfiguration(_ json: String?) {
    guard let json, !isSavingDirectConfiguration else { return }
    isSavingDirectConfiguration = true
    Task {
      defer { isSavingDirectConfiguration = false }
      do {
        let value = try JSONDecoder().decode(IPCDirectConfiguration.self, from: Data(json.utf8))
        directConfiguration = try await currentClient().updateDirectConfiguration(value)
        postToast("Direct 命令规则已应用到所有项目", symbol: "checkmark.circle.fill", tone: .success)
        errorMessage = nil
      } catch { errorMessage = Self.message(error) }
    }
  }
}
