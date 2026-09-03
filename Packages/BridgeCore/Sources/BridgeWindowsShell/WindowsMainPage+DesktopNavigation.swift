#if os(Windows)
  import BridgeDesktopUI

  extension WindowsMainPage {
    init(_ navigation: BridgeDesktopNavigation) {
      switch navigation {
      case .overview: self = .overview
      case .workbench: self = .workbench
      case .projects: self = .projects
      case .logs: self = .logs
      case .connections: self = .connections
      case .settings: self = .settings
      }
    }

    var desktopNavigation: BridgeDesktopNavigation {
      switch self {
      case .overview: .overview
      case .workbench: .workbench
      case .projects: .projects
      case .logs: .logs
      case .connections: .connections
      case .settings: .settings
      }
    }
  }
#endif
