extension CodexTranscriptPresentation {
  package static func normalizedToolStatus(_ status: String?) -> String? {
    guard let value = status?.lowercased(), !value.isEmpty else { return nil }
    switch value {
    case "completed", "success", "succeeded": return "completed"
    case "inprogress", "in_progress", "running", "active": return "inProgress"
    case "pending", "queued", "waiting": return "pending"
    case "cancelled", "canceled", "interrupted": return "cancelled"
    case "declined", "denied", "rejected": return "declined"
    case "error", "failed": return "failed"
    default: return value
    }
  }

  package static func statusLabel(_ status: String?) -> String {
    switch normalizedToolStatus(status) {
    case "completed", nil: ""
    case "failed": "失败"
    case "not_git": "非 Git 项目"
    case "declined": "已拒绝"
    case "cancelled": "已取消"
    case "pending": "等待执行"
    case "inProgress": "进行中"
    default: "状态未知"
    }
  }

  package static func resolvedToolStatus(
    providerID: String?, name: String?, status: String?, output: String
  ) -> String? {
    let normalized = normalizedToolStatus(status)
    guard normalized == "failed",
      category(providerID: providerID, name: name) == .command,
      output.lowercased().contains("fatal: not a git repository")
    else { return normalized }
    return "not_git"
  }
}
