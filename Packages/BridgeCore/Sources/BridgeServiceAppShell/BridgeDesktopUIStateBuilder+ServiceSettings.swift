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
      let message =
        keepServiceRunningAfterExit
        ? "注册后台服务后，Codex Bridge 可以在 App 退出后持续响应已启用的 MCP 客户端并维持任务执行。"
        : "注册后台服务后，Codex Bridge 会在 App 打开期间响应已启用的 MCP 客户端；按 ⌘Q 退出时停止。"
      return (
        status.rawValue,
        "未注册",
        message,
        .warning,
        [
          settingsAction,
          BridgeDesktopActionLink(
            id: "register-service",
            title: "注册后台服务",
            command: .registerService
          ),
        ]
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
        [settingsAction]
      )
    case .enabled:
      return (
        status.rawValue,
        "已启用",
        "后台 LaunchAgent 服务正在受监管运行中。",
        .success,
        [
          settingsAction,
          BridgeDesktopActionLink(
            id: "unregister-service",
            title: "停用后台服务",
            command: .unregisterService
          ),
        ]
      )
    }
  }

}
