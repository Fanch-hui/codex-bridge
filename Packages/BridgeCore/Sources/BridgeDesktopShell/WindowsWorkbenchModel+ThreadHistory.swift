#if os(Windows) || os(Linux)
  import BridgeDesktopUI
  import BridgeServiceAppCore

  extension WindowsWorkbenchModel {
    func threadHistory() -> BridgeDesktopThreadHistoryState {
      BridgeDesktopThreadHistoryState()
    }
  }
#endif
