import BridgeAgentCore
import BridgeIPC
import BridgeSecurity
import BridgeServiceCore

extension BridgeServiceRequestController {
  static func mapAgentRegistryError(
    _ error: ServiceAgentRegistryError
  ) -> BridgeServiceIPCError {
    switch error {
    case .providerUnavailable:
      return .init(
        code: "agent_provider_unavailable",
        message: "The Agent Provider adapter is unavailable."
      )
    case .installationUnavailable:
      return .init(
        code: "agent_installation_unavailable",
        message: "The Agent installation must pass Probe before it can be enabled."
      )
    case .installationNeedsReview:
      return .init(
        code: "agent_installation_needs_review",
        message: "The Agent executable changed and requires explicit local review."
      )
    case .connectionProbeFailed:
      return .init(
        code: "agent_connection_probe_failed",
        message: "The Agent installation did not pass the connection Probe."
      )
    case .connectionProbeFailedWithReason(_, let reason), .replacementProbeFailed(_, let reason):
      return .init(
        code: "agent_connection_probe_failed",
        message: OutboundContentSecurity.redactedSecrets(reason, maximumUTF8Bytes: 2_048)
      )
    case .registrationInProgress:
      return .init(
        code: "agent_registration_in_progress",
        message: "This Agent executable is already being registered.",
        retryable: true
      )
    }
  }

  static func mapSecretStoreError(_ error: SecretStoreError) -> BridgeServiceIPCError {
    switch error {
    case .accessDenied:
      return .init(
        code: "credential_store_access_denied",
        message: "系统凭据存储拒绝访问。请完成系统授权后重试。",
        retryable: true
      )
    case .keychainFailure(let status):
      return .init(
        code: "credential_store_unavailable",
        message: "系统凭据存储暂不可用（错误代码：\(status)）。请检查系统凭据存储的访问权限后重试。",
        retryable: true
      )
    case .notFound:
      return .init(code: "credentials_not_found", message: "未找到已保存的凭据，请重新配置连接。")
    case .invalidStoredValue:
      return .init(code: "credentials_invalid", message: "已保存的凭据无法读取，请重新配置连接。")
    case .invalidReference, .invalidSecret:
      return .init(code: "credentials_invalid", message: "凭据配置无效，请重新配置连接。")
    }
  }

  static func mapAgentRuntimeError(_ error: AgentRuntimeError) -> BridgeServiceIPCError {
    switch error {
    case .providerUnavailable:
      return .init(code: "agent_provider_unavailable", message: "Agent Provider 不可用。")
    case .installationUnavailable:
      return .init(code: "agent_installation_unavailable", message: "Agent 安装不可用，请重新检测连接。")
    case .processUnavailable:
      return .init(code: "agent_runtime_unavailable", message: "无法启动 Agent 运行程序，请检查安装。")
    case .processExited(let status):
      let detail = status.map { "（退出代码：\($0)）" } ?? ""
      return .init(
        code: "agent_runtime_exited", message: "Agent 运行程序已退出\(detail)。", retryable: true)
    case .timedOut:
      return .init(code: "agent_runtime_timed_out", message: "Agent 操作超时，请重试。", retryable: true)
    case .unsupportedProtocol(let reason):
      return .init(
        code: "agent_protocol_unsupported",
        message: "Agent 协议不受支持：" + safeAgentReason(reason)
      )
    case .modelUnavailable(let reason):
      return .init(
        code: "agent_model_unavailable", message: "Agent 模型不可用：" + safeAgentReason(reason))
    case .capabilityUnavailable:
      return .init(code: "agent_capability_unavailable", message: "Agent 不支持此操作。")
    case .invalidRequest(let reason):
      return .init(code: "invalid_request", message: "Agent 请求无效：" + safeAgentReason(reason))
    case .approvalUnavailable(let reason):
      return .init(
        code: "agent_approval_unavailable", message: "Agent 审批不可用：" + safeAgentReason(reason))
    case .sessionMismatch, .runMismatch:
      return .init(code: "agent_session_mismatch", message: "Agent 会话或运行身份不匹配，请重新连接。")
    case .malformedEvent, .oversizedFrame:
      return .init(code: "agent_protocol_invalid", message: "Agent 返回了无效的协议消息。")
    }
  }

  private static func safeAgentReason(_ reason: String) -> String {
    OutboundContentSecurity.redactedSecrets(reason, maximumUTF8Bytes: 2_048)
  }
}
