import BridgeAgentCore
import BridgeCodexRPC
import BridgeSecurity
import Foundation

enum ExecutionStartFailurePresentation {
  static func summary(_ error: any Error, provider: String) -> String {
    let reason =
      executionReason(error) ?? agentReason(error) ?? rpcReason(error)
      ?? "执行器未能启动任务，具体原因未识别。请查看诊断并检查连接状态。"
    let description = String(describing: error)
    let localized = (error as? LocalizedError)?.errorDescription
    let source =
      localized.map {
        $0 == description ? $0 : "\($0) [\(description)]"
      } ?? description
    let diagnostic = OutboundContentSecurity.redactedSecrets(source, maximumUTF8Bytes: 1_024)
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return "\(provider)：\(reason) 诊断详情：\(diagnostic)"
  }

  private static func executionReason(_ error: any Error) -> String? {
    guard let error = error as? ExecutionServiceError else { return nil }
    switch error {
    case .projectUnavailable, .projectIdentityChanged:
      return "注册项目目录已不可访问或身份发生变化。请检查目录并重新注册项目。"
    case .projectPermissionDenied:
      return "本机策略拒绝本次执行。请核对任务权限。"
    case .modelUnavailable, .effortUnavailable, .serviceTierUnavailable:
      return "所选模型或执行选项不可用。请核对原生配置与任务选项。"
    case .threadUnavailable, .threadMismatch, .bindingMismatch:
      return "原生会话不可用或不属于当前项目。请核对会话与项目后重新选择。"
    case .sessionLimitReached, .activeSession:
      return "执行会话已占用或达到并发限制。请等待已有任务结束。"
    case .turnStartTimedOut:
      return "Codex 未在期限内确认任务启动。请检查原生会话状态后再重试。"
    case .processUnavailable:
      return "执行器进程不可用。请在连接页检查执行引擎。"
    case .conversationPersistenceFailed:
      return "任务对话保存失败。请检查服务日志、数据目录权限与磁盘空间。"
    default:
      return nil
    }
  }

  private static func agentReason(_ error: any Error) -> String? {
    guard let error = error as? AgentRuntimeError else { return nil }
    switch error {
    case .capabilityUnavailable(.readOnlyExecution):
      return "当前 Agent 无法执行禁止写入和联网的只读任务。请选择支持只读的 Agent，或由本机用户调整任务权限。"
    case .modelUnavailable:
      return "所选 Agent 模型不可用。请刷新模型目录并核对原生模型配置。"
    case .installationUnavailable, .providerUnavailable, .processUnavailable:
      return "Agent 安装或执行器不可用。请在连接页核对安装并重新检查连接。"
    case .processExited:
      return "Agent 进程在启动期间退出。请查看退出诊断并检查原生运行环境。"
    case .timedOut:
      return "Agent 启动等待超时。请检查原生程序状态与连接。"
    case .sessionMismatch, .runMismatch:
      return "Agent 会话或执行绑定不一致。请核对原生会话后重新选择。"
    default:
      return nil
    }
  }

  private static func rpcReason(_ error: any Error) -> String? {
    guard let error = error as? CodexRPCError else { return nil }
    switch error {
    case .processLaunchFailed, .notStarted:
      return "Codex app-server 无法启动。请在连接页核对执行文件与运行环境。"
    case .processExited:
      return "Codex app-server 在任务启动期间退出。请查看退出诊断。"
    case .timeout:
      return "Codex app-server 响应超时。请核对原生会话状态和连接后重试。"
    case .remote:
      return "Codex app-server 拒绝了启动请求。请按原生错误诊断处理。"
    default:
      return nil
    }
  }
}
