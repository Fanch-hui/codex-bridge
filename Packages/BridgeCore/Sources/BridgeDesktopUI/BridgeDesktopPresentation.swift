import Foundation

public enum BridgeDesktopPresentation {
  public static func reasoningTitle(_ value: String) -> String {
    switch value.lowercased() {
    case "minimal": "最低"
    case "off": "关闭"
    case "low": "低"
    case "medium": "中"
    case "high": "高"
    case "xhigh", "extra_high": "极高"
    default: value
    }
  }

  public static func extendedReasoningTitle(_ value: String) -> String {
    switch value.lowercased() {
    case "": "Provider 默认"
    case "none": "无"
    case "max": "最高"
    case "ultra": "Ultra"
    default: reasoningTitle(value)
    }
  }

  public static func accessModeTitle(_ value: String) -> String {
    switch value {
    case "request-approval": "请求批准"
    case "auto-review": "自动评审"
    case "full-access": "完全访问"
    default: value
    }
  }

  public static func approvalModeTitle(_ value: String) -> String {
    value == "auto" ? "自动" : "每次询问"
  }

  public static func agentPermissionOptions(
    for providerID: String?
  ) -> [BridgeDesktopChoice] {
    let provider =
      providerID?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? "opencode"
    switch provider {
    case "", "opencode":
      return [
        BridgeDesktopChoice(id: "build", title: "工作区可写（Build）"),
        BridgeDesktopChoice(id: "plan", title: "只读（Plan）"),
      ]
    case "antigravity":
      return [
        BridgeDesktopChoice(id: "workspace-write", title: "工作区可写"),
        BridgeDesktopChoice(id: "plan", title: "只读（Plan）"),
      ]
    default:
      return [
        BridgeDesktopChoice(id: "workspace-write", title: "工作区可写"),
        BridgeDesktopChoice(id: "read-only", title: "只读"),
      ]
    }
  }
}
