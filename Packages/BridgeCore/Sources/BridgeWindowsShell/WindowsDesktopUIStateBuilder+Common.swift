#if os(Windows)
  import BridgeDesktopUI

  extension WindowsDesktopUIStateBuilder {
    static func header(
      _ title: String,
      _ subtitle: String,
      _ symbol: String
    ) -> BridgeDesktopPageHeader {
      BridgeDesktopPageHeader(title: title, subtitle: subtitle, symbol: symbol)
    }

    static func choice(
      _ id: String,
      _ title: String,
      detail: String? = nil,
      enabled: Bool = true
    ) -> BridgeDesktopChoice {
      BridgeDesktopChoice(id: id, title: title, detail: detail, enabled: enabled)
    }

    static func permissionChoice(_ value: String) -> BridgeDesktopChoice {
      choice(value, permissionLabel(value))
    }

    static func permissionLabel(_ value: String) -> String {
      switch value {
      case "read-only": "只读"
      case "workspace-write": "工作区可写"
      case "allowed": "允许"
      case "requiresLocalApproval": "需要本机批准"
      case "denied": "拒绝"
      default: value
      }
    }

    static func statusLabel(_ state: WindowsWorkbenchDisplay.ConnectionState)
      -> (label: String, tone: BridgeDesktopStatusTone)
    {
      switch state {
      case .idle: ("未连接", .neutral)
      case .connecting: ("连接中…", .running)
      case .connected: ("已连接", .success)
      case .unavailable: ("不可用", .error)
      }
    }
  }
#endif
