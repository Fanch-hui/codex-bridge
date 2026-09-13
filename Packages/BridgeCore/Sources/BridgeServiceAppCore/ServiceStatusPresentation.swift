import BridgeMCP
import Foundation

public enum ServiceStatusPresentation {
  public static func connectionMessage(
    status: BridgeStatusSnapshot?,
    currentMessage: String? = nil
  ) -> String? {
    var messages: [String] = []
    append(currentMessage, to: &messages)
    if let mcpMessage = mcpFailureMessage(status: status) {
      append(mcpMessage, to: &messages)
    }
    return messages.isEmpty ? nil : messages.joined(separator: "\r\n")
  }

  public static func mcpFailureMessage(status: BridgeStatusSnapshot?) -> String? {
    guard let status, status.mcpState == "failed" || status.mcpState == "local_port_unavailable"
    else {
      return nil
    }
    let reasons = status.degradations.filter { $0.hasPrefix("MCP:") }
    return reasons.isEmpty ? "本地 MCP 当前不可用，请检查后台 Service 状态。" : reasons.joined(separator: "\r\n")
  }

  private static func append(_ value: String?, to messages: inout [String]) {
    guard let value else { return }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !messages.contains(trimmed) else { return }
    messages.append(trimmed)
  }
}
