import BridgeIPC
import BridgeSecurity
import Foundation

enum ServiceRemoteFailurePresentation {
  static func message(_ error: BridgeServiceIPCError) -> String {
    let guidance = guidanceByCode[error.code]
    var lines = [guidance?.reason ?? "操作失败，具体原因未识别。"]
    let nextAction = guidance?.nextAction ?? "查看诊断详情与错误代码，结合服务日志定位原因。"
    lines.append("处理建议：\(nextAction)")
    let diagnostic = OutboundContentSecurity.redactedSecrets(
      error.message, maximumUTF8Bytes: 4 * 1_024)
    if !diagnostic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      lines.append("诊断详情：\(diagnostic)")
    }
    lines.append("错误代码：\(error.code)")
    return lines.joined(separator: "\n")
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
      ["internal_error"], "后台服务处理操作时发生未识别的错误。",
      "查看服务日志；如诊断提供关联编号，使用该编号查找对应错误。"
    ),
    (
      ["unavailable", "codex_app_server_unavailable"], "所需的本机执行组件不可用。",
      "在连接页检查后台服务与对应执行引擎，查看诊断后重新连接。"
    ),
    (
      ["agent_connection_probe_failed", "agent_runtime_probe_failed", "agent_validation_failed"],
      "Agent 连接检查未通过。", "在连接页查看检查诊断，核对安装路径和运行时后重新检查连接。"
    ),
    (
      ["agent_installation_needs_review"], "已登记的 Agent 程序或安装文件发生变化。",
      "在连接页核对新的安装文件，再确认连接。"
    ),
    (
      [
        "agent_installation_unavailable", "agent_installation_not_found",
        "agent_runtime_unavailable",
      ],
      "Agent 安装或运行时不可用。", "在连接页核对安装路径与运行时，并重新检查连接。"
    ),
    (
      ["agent_credentials_unavailable", "keychain_unavailable", "dsh_mcp_credentials_unavailable"],
      "系统凭据存储不可访问或已保存的凭据不可用。",
      "处理系统凭据授权提示；仍失败时，在对应连接设置中重新配置凭据。"
    ),
    (
      ["agent_model_catalog_failed", "agent_model_catalog_unavailable"],
      "模型目录读取失败。", "查看诊断并核对 Agent 原生配置，再刷新该 Agent 的模型列表。"
    ),
    (
      ["tunnel_not_configured", "invalid_tunnel_configuration"], "Tunnel 配置缺失或无效。",
      "在连接页核对 Tunnel 配置并保存后重新连接。"
    ),
    (
      ["tunnel_helper_unavailable"], "当前安装缺少可用的 Tunnel 组件。",
      "重新安装完整的 Codex Bridge 安装包。"
    ),
    (
      ["tunnel_unavailable"], "Tunnel 连接暂不可用。",
      "在连接页查看 Tunnel 诊断，核对网络和配置后重连。"
    ),
    (
      ["local_port_unavailable"], "本机 MCP 监听端口不可用。",
      "检查端口是否被占用，在连接设置中选择可用端口后重新启动监听。"
    ),
    (
      ["busy", "service_busy", "project_busy"], "服务或项目当前被其他操作占用。",
      "等待当前任务、命令或文件操作结束，再执行本次操作。"
    ),
    (["timeout"], "本机操作未能在期限内完成。", "查看连接状态和诊断，确认操作结果后重试。"),
  ]
}
