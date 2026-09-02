#if os(Windows)
  import WinSDK

  enum WindowsMainWindowChrome {
    private static let trayNIMAdd: DWORD = 0
    private static let trayNIMDelete: DWORD = 2
    private static let trayNIFMessage: DWORD = 0x01
    private static let trayNIFIcon: DWORD = 0x02
    private static let trayNIFTip: DWORD = 0x04
    private static let trayTipOffset = 40
    static let trayCallbackMessage: UINT = 0x8000 + 2
    private static let standardResourceID = 32_512

    nonisolated(unsafe) private static var trayData: NOTIFYICONDATAW?

    static func install(on window: HWND?) {
      installTrayIcon(on: window)
    }

    static func handleTrayMessage(_ lParam: LPARAM, window: HWND?) -> Bool {
      guard lParam == LPARAM(WM_LBUTTONDBLCLK) else { return false }
      _ = ShowWindow(window, SW_SHOW)
      _ = ShowWindow(window, SW_RESTORE)
      _ = SetForegroundWindow(window)
      return true
    }

    static func removeTrayIcon() {
      if var data = trayData {
        _ = Shell_NotifyIconW(trayNIMDelete, &data)
      }
      trayData = nil
    }

    private static func installTrayIcon(on window: HWND?) {
      guard let window else { return }
      var data = NOTIFYICONDATAW()
      data.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
      data.hWnd = window
      data.uID = UINT(1)
      data.uFlags = UINT(trayNIFMessage | trayNIFIcon | trayNIFTip)
      data.uCallbackMessage = trayCallbackMessage
      data.hIcon = LoadIconW(nil, resourcePointer(standardResourceID))
      copyTip("Codex Bridge", into: &data)
      _ = Shell_NotifyIconW(trayNIMAdd, &data)
      trayData = data
    }

    private static func copyTip(_ tip: String, into data: inout NOTIFYICONDATAW) {
      withUnsafeMutableBytes(of: &data) { raw in
        let target = raw.baseAddress!
          .advanced(by: trayTipOffset)
          .assumingMemoryBound(to: WCHAR.self)
        tip.withCString(encodedAs: UTF16.self) { source in
          var index = 0
          while source[index] != 0 && index < 127 {
            target[index] = source[index]
            index += 1
          }
          target[index] = 0
        }
      }
    }

    private static func resourcePointer(_ id: Int) -> UnsafePointer<WCHAR> {
      UnsafePointer<WCHAR>(bitPattern: id)!
    }
  }
#endif
