import Foundation

public enum ProviderRuntimeError: Error, Equatable, Sendable {
  case closed
  case busy
  case invalidMessage
  case timedOut
  case remote(String)
  case processTreeStillRunning
}

extension ProviderRuntimeError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .closed: "社区供应商宿主已关闭。"
    case .busy: "社区供应商宿主正在处理过多请求。"
    case .invalidMessage: "社区供应商返回了无效的协议消息。"
    case .timedOut: "社区供应商请求超时。"
    case .remote(let message): message
    case .processTreeStillRunning: "社区供应商宿主尚未完全退出。"
    }
  }
}
