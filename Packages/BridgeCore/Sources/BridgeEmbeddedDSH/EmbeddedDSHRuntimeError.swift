import BridgeSecurity
import Foundation

public enum EmbeddedDSHRuntimeError: Error, Equatable, Sendable {
  case invalidConfiguration
  case resourcesUnavailable
  case invalidManifest
  case incompatibleRuntime
  case resourceChanged(String)
  case launchFailed
  case protocolViolation
  case busy
  case startupTimedOut
  case requestTimedOut
  case transportClosed
  case processExited(Int32?)
  case stopped
  case processTreeStillRunning
  case remote(code: Int, message: String)
}

extension EmbeddedDSHRuntimeError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      "工作台运行配置无效。"
    case .resourcesUnavailable:
      "未找到工作台运行资源。"
    case .invalidManifest:
      "工作台运行资源清单无效。"
    case .incompatibleRuntime:
      "工作台运行资源与当前平台不匹配。"
    case .resourceChanged(let path):
      "工作台运行文件校验失败：\(path)"
    case .launchFailed:
      "工作台引擎启动失败。"
    case .protocolViolation:
      "工作台引擎返回了无效数据。"
    case .busy:
      "工作台引擎正在处理过多请求，请稍后重试。"
    case .startupTimedOut:
      "工作台引擎启动超时，请重试。"
    case .requestTimedOut:
      "工作台请求超时。"
    case .transportClosed:
      "工作台引擎连接已关闭。"
    case .processExited(let code):
      code.map { "工作台引擎已退出（\($0)）。" } ?? "工作台引擎已退出。"
    case .stopped:
      "工作台引擎已停止。"
    case .processTreeStillRunning:
      "工作台的进程尚未确认退出，暂时无法启动。"
    case .remote(_, let message):
      OutboundContentSecurity.redactedSecrets(message, maximumUTF8Bytes: 4 * 1_024)
    }
  }
}

/// A callback error whose message is safe to return to the embedded host.
public struct EmbeddedDSHCallbackError: Error, Sendable {
  public let code: Int
  public let message: String

  public init(code: Int, message: String) {
    self.code = code
    self.message = OutboundContentSecurity.redactedSecrets(message, maximumUTF8Bytes: 4 * 1_024)
  }
}
