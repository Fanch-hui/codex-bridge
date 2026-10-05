public enum BridgeDesktopProjectPresentation {
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
