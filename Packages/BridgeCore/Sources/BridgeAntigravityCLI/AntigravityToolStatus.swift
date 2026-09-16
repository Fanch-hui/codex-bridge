import BridgeAgentCore
import Foundation

enum AntigravityToolStatus {
  static let states: Set<String> = [
    "ACTIVE", "DONE", "ERROR", "CANCELED", "CANCELLED", "INTERRUPTED",
    "DECLINED", "DENIED", "REJECTED", "PENDING", "WAITING",
  ]

  static func resolve(state: String, error: AntigravityToolError?) -> AgentToolStatus {
    let errorType = error?.type?.uppercased() ?? ""
    let cancelled: Set<String> = ["CANCELED", "CANCELLED", "INTERRUPTED"]
    if cancelled.contains(state) || cancelled.contains(errorType) { return .cancelled }
    let declined: Set<String> = ["DECLINED", "DENIED", "REJECTED", "PERMISSION_DENIED"]
    if declined.contains(state) || declined.contains(errorType) { return .declined }
    if AntigravityPermissionEvidence.detected(in: error?.message) || errorType == "PERMISSION" {
      return state == "ACTIVE" || state == "WAITING" ? .pending : .declined
    }
    let message = error?.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if state == "ERROR" || !errorType.isEmpty || !message.isEmpty { return .failed }
    switch state {
    case "DONE": return .completed
    case "PENDING", "WAITING": return .pending
    default: return .inProgress
    }
  }
}
