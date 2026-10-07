import BridgeAgentCore
import BridgeDeepSeekHarnessDesktop
import BridgeIPC
import Foundation

extension BridgeServiceRequestController {
  static func mapDeepSeekDesktopError(_ error: any Error) -> BridgeServiceIPCError? {
    if let error = error as? DeepSeekHarnessDesktopRPCError {
      return .init(
        code: error.code, message: error.message,
        retryable: [
          "desktop_unavailable", "desktop_client_unavailable", "desktop_connector_not_ready",
        ]
        .contains(error.code))
    }
    if let error = error as? ServiceDeepSeekDesktopInstallError {
      let code: String
      switch error {
      case .unsupportedPlatform: code = "dsh_desktop_platform_unsupported"
      case .desktopInstallationRequired: code = "dsh_desktop_installation_required"
      case .desktopMustExit: code = "dsh_desktop_must_exit"
      case .installationFailed: code = "dsh_desktop_connector_install_failed"
      }
      return .init(code: code, message: error.localizedDescription)
    }
    if case .unsupportedProtocol(let detail) = error as? AgentRuntimeError,
      detail == "dsh_desktop_profile_changed"
    {
      return .init(
        code: "dsh_desktop_profile_changed",
        message: "DSH 桌面的 profile 或身份已变化，请在连接页重新配对。")
    }
    if case .unsupportedProtocol(let detail) = error as? AgentRuntimeError,
      detail == "dsh_desktop_platform_unsupported"
    {
      return .init(
        code: detail,
        message: "DSH 原生桌面当前支持 macOS 和 Windows x64；此平台请使用 ACP。")
    }
    if case .unsupportedProtocol("dsh_desktop_identity") = error as? AgentRuntimeError {
      return .init(
        code: "dsh_desktop_identity_invalid",
        message: "DSH Desktop Connector 的运行身份校验失败。请完全退出 DSH 桌面后重新检测安装与连接。")
    }
    return nil
  }
}
