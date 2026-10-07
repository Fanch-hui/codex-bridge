import BridgeIPC
import BridgeSecurity
import Foundation

public enum AgentConnectionFailurePresentation {
  public static func message(for installation: IPCAgentInstallationSummary) -> String {
    if let reason = installation.lastProbeError?.trimmingCharacters(in: .whitespacesAndNewlines),
      !reason.isEmpty
    {
      let diagnostic = OutboundContentSecurity.redactedSecrets(reason, maximumUTF8Bytes: 4 * 1_024)
      return "\(installation.displayName) 连接检查未通过。\n诊断详情：\(diagnostic)\n请在连接页核对安装路径与运行时，再重新检查连接。"
    }
    return "已发现 \(installation.displayName)，但连接检查未通过，尚无具体诊断。请在连接页核对安装路径与运行时，再重新检查连接；仍失败时查看服务日志。"
  }
}
