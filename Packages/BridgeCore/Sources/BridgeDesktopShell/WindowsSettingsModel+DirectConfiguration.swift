#if os(Windows) || os(Linux)
  import BridgeIPC
  import BridgeDesktopUI
  import BridgeServiceAppCore
  import Foundation

  extension WindowsSettingsModel {
    func saveDirectConfiguration(_ json: String) async {
      guard !busy, connectionState == .connected else { return }
      busy = true
      directCommandChecker.invalidate()
      publishDisplay()
      defer {
        busy = false
        publishDisplay()
      }
      do {
        let value = try JSONDecoder().decode(IPCDirectConfiguration.self, from: Data(json.utf8))
        directConfiguration = try await client.updateDirectConfiguration(value)
        statusText = "Direct 命令规则已应用到所有项目。"
      } catch { statusText = "保存 Direct 规则失败：\(BridgeServiceErrorMessage.message(error))" }
    }

    func checkDirectCommand(_ envelope: BridgeDesktopCommandEnvelope) {
      let payload = envelope.payload
      guard !busy, connectionState == .connected,
        let projectID = BridgeDesktopCommandValue.nonEmpty(payload.projectID),
        directCommandProjects.contains(where: { $0.projectID == projectID }),
        let command = BridgeDesktopCommandValue.nonEmpty(payload.input, maximumUTF8Bytes: 4_096)
      else {
        statusText = "请选择已登记项目并输入一条命令，连接后台服务后再校验。"
        publishDisplay()
        return
      }
      directCommandChecker.check(
        IPCDirectCommandCheckRequest(
          projectID: projectID, commandLine: command,
          workingDirectory: payload.workingDirectory?.trimmingCharacters(
            in: .whitespacesAndNewlines),
          requestID: envelope.requestID))
    }
  }
#endif
