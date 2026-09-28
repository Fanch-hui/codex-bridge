#if os(Windows)
  import BridgeDesktopUI

  enum WindowsDesktopUICommandRouter {
    static func command(for envelope: BridgeDesktopCommandEnvelope) -> MainWindowCommand? {
      switch envelope.command {
      case .ready, .requestStateResync, .openSystemSettings:
        return nil
      default:
        return .desktopCommand(envelope)
      }
    }
  }
#endif
