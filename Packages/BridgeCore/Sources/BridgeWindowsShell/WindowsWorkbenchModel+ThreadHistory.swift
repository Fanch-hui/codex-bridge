#if os(Windows)
  import BridgeDesktopUI
  import BridgeServiceAppCore

  extension WindowsWorkbenchModel {
    func threadHistory() -> BridgeDesktopThreadHistoryState {
      BridgeDesktopThreadHistoryState()
    }
  }
#endif
