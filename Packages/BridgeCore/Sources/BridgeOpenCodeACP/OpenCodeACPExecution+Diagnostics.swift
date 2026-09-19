import BridgeSecurity
import Foundation

extension OpenCodeACPExecution {
  static func failureSummary(_ error: any Error) -> String {
    switch error {
    case OpenCodeACPError.requestTimedOut:
      return "OpenCode ACP request timed out."
    case OpenCodeACPError.processExited:
      return "OpenCode ACP process exited before completion."
    case OpenCodeACPError.oversizedFrame:
      return "OpenCode ACP exceeded a protocol size limit."
    case OpenCodeACPError.sessionMismatch:
      return "OpenCode ACP reported an unexpected session."
    case OpenCodeACPError.remote(let code, let message):
      let detail = OutboundContentSecurity.redactedSecrets(message, maximumUTF8Bytes: 2_048)
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
      return detail.isEmpty
        ? "OpenCode ACP returned protocol error \(code)."
        : "OpenCode ACP returned protocol error \(code): \(detail)"
    default:
      return "OpenCode ACP execution failed."
    }
  }
}
