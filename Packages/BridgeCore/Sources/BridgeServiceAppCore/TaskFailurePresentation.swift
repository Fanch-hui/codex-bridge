import BridgeMCP
import BridgeSecurity
import Foundation

public struct TaskFailurePresentation: Equatable, Sendable {
  public let reason: String
  public let nextAction: String
  public let diagnostic: String?

  public static func failure(for task: MCPServiceTaskSnapshot) -> Self? {
    guard task.status == "failed" else { return nil }
    let guidance = guidanceByCode[task.failureCode ?? ""]
    let summary = task.resultSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
    return Self(
      reason: guidance?.reason ?? "任务失败，具体原因未识别。",
      nextAction: guidance?.nextAction ?? "查看失败代码和诊断详情，结合 Agent 原生记录或服务日志定位原因。",
      diagnostic: summary.flatMap {
        $0.isEmpty ? nil : OutboundContentSecurity.redactedSecrets($0, maximumUTF8Bytes: 4 * 1_024)
      }
    )
  }

  private struct Guidance: Sendable {
    let reason: String
    let nextAction: String
  }

  private static let guidanceByCode = Dictionary(
    uniqueKeysWithValues: guidanceRows.flatMap { row in
      row.0.map { ($0, Guidance(reason: row.1, nextAction: row.2)) }
    }
  )

  private static let guidanceRows: [([String], String, String)] = [
    (
      [
        "claude_authentication_required", "claude_authentication_failed",
        "claude_oauth_org_not_allowed",
      ],
      "Claude Code 的认证或组织授权未通过。",
      "在连接页完成官方登录并核对组织授权，再继续原会话。"
    ),
    (
      ["claude_rate_limit"], "Claude 服务返回用量或请求频率限制。",
      "查看官方账号的限制与恢复时间，稍后继续原会话。"
    ),
    (
      ["claude_account_on_hold", "claude_verification_required"], "Claude 账号需要处理验证或账号限制。",
      "在官方账号页面完成对应处理，再继续原会话。"
    ),
    (
      ["claude_cloud_credential_error"], "Claude Code 未能取得当前云服务的认证。",
      "完成对应云服务的原生登录，再检查 Claude Code 连接。"
    ),
    (
      ["claude_billing_error"], "Claude 服务返回计费错误。",
      "核对当前认证来源及对应官方计费状态，再继续任务。"
    ),
    (
      ["claude_model_not_found"], "Claude 当前认证来源无法使用所选模型。",
      "刷新 Claude Code 模型目录，选择当前来源可用的模型。"
    ),
    (
      ["claude_overloaded", "claude_server_error"], "Claude 服务暂时无法处理本次请求。",
      "稍后继续原会话，重试前核对已发生的文件变更。"
    ),
    (
      ["claude_cli_incompatible"], "Claude Code 运行时不支持当前执行协议。",
      "在连接页更新或修复 Claude Code，然后重新验证连接。"
    ),
    (
      ["claude_permission_denied", "claude_sandbox_unavailable"], "Claude Code 无法按当前权限执行工具。",
      "核对本机任务权限和原生运行环境，再决定是否重新授权。"
    ),
    (
      ["claude_session_busy"], "Claude 原生会话仍被其他执行占用。",
      "结束该会话的已有执行后，再继续原会话。"
    ),
    (
      ["execution_start_failed", "agent_start_failed", "queued_start_failed"],
      "执行器未能启动任务。",
      "先查看诊断详情；在连接页检查执行器状态，排除启动问题后重试任务。"
    ),
    (
      ["agent_read_only_unavailable"], "当前 Agent 无法执行禁止写入和联网的只读任务。",
      "选择支持只读执行的 Agent；需要写入或联网时，由本机用户调整任务权限。"
    ),
    (
      ["agent_model_unavailable", "queued_model_unavailable"], "任务选择的模型不可用。",
      "在设置页刷新对应 Agent 的模型列表，核对原生配置后重新选择模型。"
    ),
    (
      ["queued_project_missing"], "排队期间项目已取消注册。",
      "在项目页重新注册目录，再创建任务。"
    ),
    (
      ["queued_project_unavailable"], "注册的项目目录已不可访问或目录身份已变化。",
      "检查目录是否被移动、替换或卸载，核对后重新注册项目。"
    ),
    (
      ["queued_agent_unavailable"], "排队时绑定的 Agent 安装已不可用。",
      "在连接页核对该安装并重新检查连接，再重试任务。"
    ),
    (
      ["conversation_persistence_failed", "execution_state_update_failed"],
      "服务无法保存任务对话或执行状态。",
      "查看服务日志，检查服务数据目录的访问权限和磁盘空间；重试前核对已发生的文件变更。"
    ),
    (
      ["agent_execution_failed"], "Agent 事件处理或任务状态保存失败。",
      "查看诊断详情和服务日志，核对 Agent 原生结果及文件变更后再决定是否重试。"
    ),
    (
      [
        "agent_stream_ended", "execution_stream_ended", "codex_transport_failed",
        "antigravity_transport_closed", "qoder_transport_failed",
      ],
      "执行通道在确认最终结果前断开。",
      "检查 Agent 连接并核对原生会话和文件变更；确认执行状态后再续写或重试。"
    ),
    (
      ["codex_process_exited", "desktop_host_exited", "desktop_host_restarted"],
      "Agent 进程退出或重新启动，任务结果未确认。",
      "检查原生程序是否仍在运行和对应诊断，核对已有结果后重新连接。"
    ),
    (
      ["codex_protocol_line_too_large", "codex_transport_capacity"],
      "Codex 消息超过执行通道容量。",
      "查看诊断中的容量限制，减少单次任务的大量输出，核对已有变更后重试。"
    ),
    (
      [
        "codex_protocol_invalid", "invalid_turn_completed", "turn_binding_mismatch",
        "duplicate_turn_completion", "invalid_turn_status", "antigravity_protocol_violation",
        "desktop_event_invalid",
      ],
      "Agent 返回的执行事件不符合当前协议或会话绑定。",
      "在连接页检查 Agent 版本与连接，查看诊断和原生记录后重新连接。"
    ),
    (
      ["codex_turn_failed", "pi_execution_failed", "desktop_run_failed"],
      "Agent 报告本次执行失败。",
      "查看 Agent 返回的诊断详情，按原生错误处理后再续写或重试。"
    ),
    (
      ["antigravity_permission_denied"], "Antigravity 拒绝了任务所需的工具权限。",
      "按权限处理入口检查原生权限设置，确认任务权限后重试。"
    ),
    (
      ["antigravity_inactivity_timeout"], "Antigravity 长时间未返回执行活动，等待已超时。",
      "检查原生程序是否仍在执行或等待操作，核对执行状态后再重试。"
    ),
    (
      ["agent_approval_expired"], "任务等待本机审批超时。",
      "准备好完成本机审批后重试任务。"
    ),
    (
      [
        "agent_approval_binding_mismatch", "agent_approval_state_failed",
        "agent_approval_response_failed",
      ],
      "本机审批未能应用到对应的 Agent 执行。",
      "查看诊断并检查连接状态，确认原生会话已结束后重试。"
    ),
    (
      ["agent_user_input_timeout_failed"], "Agent 问题等待超时，且取消答复未能送达。",
      "检查原生程序是否仍在等待回答，确认其执行状态后重试。"
    ),
  ]
}
