public enum BridgeDesktopProjectPresentation {
  public static let readPermissionOptions = [
    BridgeDesktopChoice(id: "denied", title: "拒绝"),
    BridgeDesktopChoice(id: "allowed", title: "允许"),
  ]

  public static let guardedPermissionOptions = [
    BridgeDesktopChoice(id: "denied", title: "拒绝"),
    BridgeDesktopChoice(id: "requiresLocalApproval", title: "需要本机批准"),
    BridgeDesktopChoice(id: "allowed", title: "允许"),
  ]

  public static let policyOptions = guardedPermissionOptions

  public static let workspaceCommandModeOptions = [
    BridgeDesktopChoice(id: "denied", title: "禁止直接执行"),
    BridgeDesktopChoice(id: "safe", title: "安全模式"),
    BridgeDesktopChoice(id: "full", title: "完全模式"),
  ]

  public static func workspaceCommandModeChoice(_ value: String) -> BridgeDesktopChoice {
    workspaceCommandModeOptions.first(where: { $0.id == value })
      ?? BridgeDesktopChoice(id: value, title: value)
  }
}
