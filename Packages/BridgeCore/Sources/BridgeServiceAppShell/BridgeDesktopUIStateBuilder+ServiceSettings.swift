import BridgeDesktopUI
import BridgeServiceAppCore

extension BridgeDesktopUIStateBuilder {
  static func servicePresentation(
    status: BridgeServiceRegistrationStatus,
    keepServiceRunningAfterExit: Bool
  ) -> (
    status: String,
    title: String,
    message: String,
    tone: BridgeDesktopStatusTone,
    actions: [BridgeDesktopActionLink]
  ) {
    let settingsAction = BridgeDesktopActionLink(
      id: "open-system-settings",
      title: "打开 macOS 登录项设置",
      command: .openSystemSettings
    )
    switch status {
    case .notRegistered:
      return (
        status.rawValue,
        "未注册",
        "启动时会自动注册后台 Service。",
        .warning,
        []
      )
    case .requiresApproval:
      return (
        status.rawValue,
        "等待批准",
        "系统已登记后台项，请前往“系统设置 → 通用 → 登录项”允许 Codex Bridge 在后台运行。",
        .warning,
        [settingsAction]
      )
    case .notFound:
      return (
        status.rawValue,
        "配置缺失",
        "当前 App Bundle 中未检测到打包的 Service plist 配置，请重新构建项目。",
        .error,
        []
      )
    case .enabled:
      return (
        status.rawValue,
        "已启用",
        "后台 LaunchAgent 服务正在受监管运行中。",
        .success,
        []
      )
    }
  }

}
