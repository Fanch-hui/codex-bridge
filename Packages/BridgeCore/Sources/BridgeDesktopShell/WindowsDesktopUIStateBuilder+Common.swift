#if os(Windows) || os(Linux)
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
