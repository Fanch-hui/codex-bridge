import BridgeIPC
import BridgeSecurity
import Foundation

public enum BridgeServiceErrorMessage {
  /// Renders a user-facing message for IPC transport and remote errors.
  public static func message(_ error: any Error) -> String {
    if let codec = error as? BridgeServiceIPCCodecError {
      switch codec {
      case .requestMismatch:
        return "后台服务返回的响应与本次请求不匹配。请重启 App 与后台服务后重试。"
      case .unsupportedSchemaVersion:
        return "后台 Service 与本 App 的 IPC 版本不一致，请重新注册或重启后台 Service。"
      case .messageTooLarge:
        return "本机通信数据超过容量限制。请缩小单次操作的数据量后重试。"
      case .invalidMessage, .missingPayload:
        return "后台服务返回的本机通信数据无效或缺少内容。请核对 App 与服务版本并重启后重试。"
      case .remoteError(let remote):
        return ServiceRemoteFailurePresentation.message(remote)
      }
    }
    if let localized = error as? LocalizedError,
      let description = localized.errorDescription
    {
      return OutboundContentSecurity.redactedSecrets(description, maximumUTF8Bytes: 4 * 1_024)
    }
    let nsError = error as NSError
    let diagnostic = OutboundContentSecurity.redactedSecrets(
      nsError.localizedDescription, maximumUTF8Bytes: 4 * 1_024)
    return "操作失败：\(diagnostic)\n错误标识：\(nsError.domain) / \(nsError.code)"
  }
}
