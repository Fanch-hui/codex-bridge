#if os(Windows)
  import WinSDK

  enum WindowsMainWindowLifecycle {
    static let chatStoppedMessage = UINT(WM_APP + 40)
    static let desktopStoppedMessage = UINT(WM_APP + 41)
    nonisolated(unsafe) private static var isExiting = false
    nonisolated(unsafe) private static var pendingSurfaces = 0

    static func requestExit(_ window: HWND?) {
      guard !isExiting, let window else { return }
      isExiting = true
      if WindowsMainWindow.chat?.beginShutdown(notifying: window, message: chatStoppedMessage)
        == true
      {
        pendingSurfaces += 1
      }
      if WindowsMainWindow.desktopUI?.beginShutdown(
        notifying: window, message: desktopStoppedMessage) == true
      {
        pendingSurfaces += 1
      }
      if pendingSurfaces > 0 {
        _ = EnableWindow(window, false)
      } else {
        _ = DestroyWindow(window)
      }
    }

    static func finishWebViewShutdown(_ window: HWND?) {
      guard isExiting else { return }
      pendingSurfaces = max(0, pendingSurfaces - 1)
      if pendingSurfaces == 0 { _ = DestroyWindow(window) }
    }

    static func reset() {
      isExiting = false
      pendingSurfaces = 0
    }
  }
#endif
