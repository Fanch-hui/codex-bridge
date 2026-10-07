import BridgeDesktopUI
import BridgeIPC
import Foundation

extension BridgeServiceAppModel {
  func saveDirectConfiguration(_ json: String?) {
    guard let json, !isSavingDirectConfiguration else { return }
    isSavingDirectConfiguration = true
    directCommandChecker.invalidate()
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

  func checkDirectCommand(_ envelope: BridgeDesktopCommandEnvelope) {
    let payload = envelope.payload
    guard connectionState == .connected, !isSavingDirectConfiguration,
      let projectID = BridgeDesktopCommandValue.nonEmpty(payload.projectID),
      projects.contains(where: { $0.projectID == projectID }),
      let command = BridgeDesktopCommandValue.nonEmpty(payload.input, maximumUTF8Bytes: 4_096)
    else {
      errorMessage = "请选择已登记项目并输入一条命令，连接后台服务后再校验。"
      return
    }
    directCommandChecker.check(
      IPCDirectCommandCheckRequest(
        projectID: projectID, commandLine: command,
        workingDirectory: payload.workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
        requestID: envelope.requestID))
  }
}
