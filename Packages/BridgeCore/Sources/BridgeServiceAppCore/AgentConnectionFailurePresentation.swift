import BridgeIPC
import Foundation

public enum AgentConnectionFailurePresentation {
  public static func message(for installation: IPCAgentInstallationSummary) -> String {
    if let reason = installation.lastProbeError?.trimmingCharacters(in: .whitespacesAndNewlines),
      !reason.isEmpty
    {
      return reason
    }
    return "已发现 \(installation.displayName)，但连接检查未通过"
  }
}
