extension ApprovalPresentation {
  public static func decisionTitle(_ decision: String) -> String {
    switch decision {
    case "deny": "拒绝"
    case "allow_for_session": "本次会话允许"
    case "allow_similar_commands": "允许此类命令"
    default: "仅本次允许"
    }
  }
}
