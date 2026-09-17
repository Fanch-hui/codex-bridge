#if os(Windows)
  import WinSDK

  extension WindowsWebViewThread {
    func windowHandle() -> HWND? {
      guard threadID != 0 else { return nil }
      var child = FindWindowExW(parentWindow, nil, nil, nil)
      while let current = child {
        if GetWindowThreadProcessId(current, nil) == threadID {
          return current
        }
        child = FindWindowExW(parentWindow, current, nil, nil)
      }
      return nil
    }

    func bringToTop() {
      guard let hwnd = windowHandle() else { return }
      _ = SetWindowPos(
        hwnd,
        nil,
        0,
        0,
        0,
        0,
        UINT(SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE)
      )
    }
  }
#endif
