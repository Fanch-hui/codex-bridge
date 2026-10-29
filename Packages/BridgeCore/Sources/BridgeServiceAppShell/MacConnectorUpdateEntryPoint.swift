import BridgeIPC
import Darwin
import Dispatch
import Foundation

public enum MacConnectorUpdateEntryPoint {
  public static func runIfRequested() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.first == "--update-dsh-connector" else { return }
    guard let installationID = ConnectorUpdateCommand.installationID(arguments: arguments) else {
      writeError("用法：CodexBridge --update-dsh-connector <安装 ID> [--accept-replacement]")
      exit(64)
    }
    Task.detached {
      let client = BridgeServiceClient(transport: ServiceTransportFactory.defaultTransport())
      do {
        try await ConnectorUpdateCommand.update(
          installationID: installationID,
          acceptReplacement: arguments.last == "--accept-replacement", client: client)
        await client.invalidate()
        print("DSH Desktop 连接器已更新。")
        exit(0)
      } catch {
        await client.invalidate()
        writeError(ConnectorUpdateCommand.errorMessage(error))
        exit(1)
      }
    }
    dispatchMain()
  }

  private static func writeError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
  }
}

enum ConnectorUpdateCommand {
  static func installationID(arguments: [String]) -> String? {
    guard arguments.count == 2 || (arguments.count == 3 && arguments[2] == "--accept-replacement"),
      arguments[0] == "--update-dsh-connector"
    else { return nil }
    let value = arguments[1]
    guard !value.isEmpty, value.utf8.count <= 128,
      value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.contains("\0"), value.rangeOfCharacter(from: .controlCharacters) == nil
    else { return nil }
    return value
  }

  static func update(
    installationID: String, acceptReplacement: Bool = false, client: BridgeServiceClient
  ) async throws {
    if acceptReplacement {
      _ = try await client.reprobeAgentInstallation(
        installationID: installationID, acceptReplacement: true)
    }
    let state = try await client.manageDeepSeekHarnessDesktop(
      .init(installationID: installationID, action: .installConnector))
    guard state.connectorInstalled, state.connectorUpdateAvailable != true else {
      throw ConnectorUpdateError.missingReceipt
    }
  }

  static func errorMessage(_ error: any Error) -> String {
    if let ipcError = error as? BridgeServiceIPCCodecError {
      return ipcErrorMessage(ipcError)
    }
    if error is ConnectorUpdateError {
      return "连接器更新未得到安装确认，请在 Bridge 连接页检查连接状态。"
    }
    if let clientError = error as? BridgeServiceClientError {
      return clientErrorMessage(clientError)
    }
    if error is DecodingError {
      return "无法解析后台服务的 IPC 回复。"
    }
    if error is EncodingError {
      return "无法编码连接器更新的 IPC 请求。"
    }
    return "DSH Desktop 连接器更新失败，请在 Bridge 连接页检查连接状态。"
  }

  private static func ipcErrorMessage(_ error: BridgeServiceIPCCodecError) -> String {
    switch error {
    case .messageTooLarge:
      return "IPC 消息为空或超出大小限制，请检查 Bridge 后台服务状态。"
    case .invalidMessage:
      return "IPC 请求或回复的格式无效，请检查 Bridge 后台服务状态。"
    case .unsupportedSchemaVersion:
      return "后台服务的 IPC 协议版本不兼容，请检查已安装的 Bridge 与后台服务版本。"
    case .requestMismatch:
      return "后台服务的 IPC 回复与请求不匹配。"
    case .missingPayload:
      return "后台服务的 IPC 回复缺少操作结果。"
    case .remoteError(let remote):
      let message = remoteErrorMessage(code: remote.code)
      guard remote.code == "dsh_desktop_connector_install_failed",
        let code = remote.diagnosticCode, isSafeDiagnosticCode(code)
      else { return message }
      return message + "（诊断代码：\(code)）"
    }
  }

  private static func remoteErrorMessage(code: String) -> String {
    switch code {
    case "dsh_desktop_must_exit":
      return "请完全退出 DSH Desktop 后重试更新连接器。"
    case "invalid_state":
      return "当前状态不允许更新连接器，请检查 DSH 是否存在未结束的原生任务。"
    case "dsh_desktop_installation_required", "agent_installation_not_found":
      return "未找到 DSH Desktop 安装，请在 Bridge 中重新扫描后重试。"
    case "agent_installation_needs_review":
      return "DSH Desktop 安装已更新，请重新检测并确认替换；命令行可显式添加 --accept-replacement。"
    case "dsh_desktop_connector_install_failed":
      return "连接器安装失败，请检查 DSH 插件安装环境和诊断代码。"
    default:
      guard isSafeErrorCode(code) else {
        return "DSH Desktop 连接器更新失败（错误代码无效），请在 Bridge 连接页检查连接状态。"
      }
      return "DSH Desktop 连接器更新失败（错误代码：\(code)），请在 Bridge 连接页检查连接状态。"
    }
  }

  private static func isSafeErrorCode(_ code: String) -> Bool {
    guard !code.isEmpty, code.utf8.count <= 64 else { return false }
    return code.utf8.allSatisfy { byte in
      (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57) || byte == 95
    }
  }

  private static func isSafeDiagnosticCode(_ code: String) -> Bool {
    guard !code.isEmpty, code.utf8.count <= 64 else { return false }
    return code.utf8.allSatisfy { byte in
      (byte >= 65 && byte <= 90) || (byte >= 48 && byte <= 57) || byte == 95
    }
  }

  private static func clientErrorMessage(_ error: BridgeServiceClientError) -> String {
    switch error {
    case .unavailable:
      return "无法连接 Bridge 后台服务，请先启动 Codex Bridge 后重试。"
    case .invalidRemoteProxy:
      return "无法建立后台服务的 IPC 代理。"
    case .responseFailed:
      return "后台服务无法返回 IPC 操作结果。"
    case .serviceRestartRequired:
      return "后台服务需要重新启动，请在任务结束后重试。"
    }
  }
}

private enum ConnectorUpdateError: Error {
  case missingReceipt
}
