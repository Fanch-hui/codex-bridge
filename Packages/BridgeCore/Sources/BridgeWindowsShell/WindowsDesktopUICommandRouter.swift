#if os(Windows)
  import BridgeDesktopUI
  import Foundation

  enum WindowsDesktopUICommandRouter {
    static func command(for envelope: BridgeDesktopCommandEnvelope) -> MainWindowCommand? {
      switch envelope.command {
      case .ready:
        return nil
      case .refresh:
        return .refreshCurrentPage
      case .selectPage:
        guard let navigation = envelope.payload.navigation else { return nil }
        return select(navigation)
      case .openWorkbench:
        return select(.workbench)
      case .openProjects:
        return select(.projects)
      case .openConnections:
        return select(.connections)
      case .openSettings:
        return select(.settings)
      case .openLogs:
        return select(.logs)
      case .openTask:
        guard
          let taskID = envelope.payload.taskID?.trimmingCharacters(in: .whitespacesAndNewlines),
          !taskID.isEmpty,
          taskID.count <= 256
        else { return nil }
        return .openTask(id: taskID)
      }
    }

    private static func select(_ navigation: BridgeDesktopNavigation) -> MainWindowCommand {
      .selectPage(index: WindowsMainPage(navigation).rawValue)
    }
  }

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
