import BridgeAgentCore
import BridgeSecurity

/// Why an SDK host execution stopped before the host reported a result of its own. The reason is
/// built from the error's type only, so it never carries host output or file content.
public enum AgentHostFailure: Equatable, Sendable {
  /// The input was not accepted: an attachment is gone or changed, or the request is invalid.
  case input(reason: String)
  /// The host sent a message outside the protocol or the session it is bound to.
  case protocolViolation
  /// The channel closed or stopped answering; nothing is known about the result.
  case transport

  public init(_ error: (any Error)?) {
    switch error {
    case let error as SecureProjectImageError:
      self = .input(reason: Self.reason(error))
    case let error as PathSecurityError:
      self = .input(reason: error == .pathDoesNotExist ? "附件已不存在" : "附件未通过项目文件校验")
    case AgentRuntimeError.invalidRequest(let field)?:
      self = .input(reason: "输入不符合要求（\(field)）")
    case ACPError.remote(let code, _)?:
      self = .input(reason: "宿主拒绝了请求（\(code)）")
    case ACPError.invalidMessage?, ACPError.malformedResponse?, ACPError.oversizedFrame?,
      AgentRuntimeError.sessionMismatch?, AgentRuntimeError.runMismatch?,
      AgentRuntimeError.malformedEvent?, AgentRuntimeError.oversizedFrame?:
      self = .protocolViolation
    default:
      self = .transport
    }
  }

  private static func reason(_ error: SecureProjectImageError) -> String {
    switch error {
    case .changed(let path): "附件 \(path) 在提交后发生了变化"
    case .emptyImage: "附件内容为空"
    case .unsupportedImageFormat: "附件不是受支持的图片格式"
    }
  }

  /// The terminal event for a provider: `<provider>_input_rejected`, `_protocol_failed` or
  /// `_transport_failed`. None of them confirms that the provider's processes have exited.
  public func event(providerID: String, providerName: String) -> AgentEvent {
    switch self {
    case .input(let reason):
      .failed(code: "\(providerID)_input_rejected", summary: "\(providerName) 未接受本次输入：\(reason)。")
    case .protocolViolation:
      .failed(
        code: "\(providerID)_protocol_failed",
        summary: "\(providerName) 宿主返回了不符合协议的消息，任务结果未确认。")
    case .transport:
      .failed(
        code: "\(providerID)_transport_failed", summary: "\(providerName) 执行通道关闭，任务结果未确认。")
    }
  }
}
