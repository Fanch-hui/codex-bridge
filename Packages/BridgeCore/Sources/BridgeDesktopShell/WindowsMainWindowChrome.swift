#if os(Windows)
  import WinSDK

  enum WindowsMainWindowChrome {
    private static let trayNIMAdd: DWORD = 0
    private static let trayNIMModify: DWORD = 1
    private static let trayNIMDelete: DWORD = 2
    private static let trayNIMSetFocus: DWORD = 3
    private static let trayNIFMessage: DWORD = 0x01
    private static let trayNIFIcon: DWORD = 0x02
    private static let trayNIFTip: DWORD = 0x04
    private static let trayTipOffset = 40
    private static let trayIconID = UINT(1)
    static let trayCallbackMessage: UINT = 0x8000 + 2
    private static let standardResourceID = 32_512

    private enum MenuCommand {
      static let openWorkbench = 10_001
      static let openMainWindow = 10_002
      static let refresh = 10_003
      static let exit = 10_004
    }

    nonisolated(unsafe) private static var trayData: NOTIFYICONDATAW?
    nonisolated(unsafe) private static var currentTooltip = "Codex Bridge"

    static func install(on window: HWND?) {
      installTrayIcon(on: window)
    }

    static func handleTrayMessage(_ lParam: LPARAM, window: HWND?) -> Bool {
      switch lParam {
      case LPARAM(WM_LBUTTONUP), LPARAM(WM_LBUTTONDBLCLK), LPARAM(WM_USER),
        LPARAM(WM_USER + 1):
        restore(window)
        return true
      case LPARAM(WM_RBUTTONUP), LPARAM(WM_CONTEXTMENU):
        showContextMenu(for: window)
        return true
      default:
        return false
      }
    }

    static func handleCommand(_ wParam: WPARAM, window: HWND?) -> Bool {
      let commandID = Int(UInt(wParam) & 0xFFFF)
      switch commandID {
      case MenuCommand.openWorkbench:
        WindowsMainWindow.enqueue(.selectPage(index: WindowsMainPage.workbench.rawValue))
        activate(window)
      case MenuCommand.openMainWindow:
        activate(window)
      case MenuCommand.refresh:
        WindowsMainWindow.enqueue(.refreshAll)
      case MenuCommand.exit:
        _ = PostMessageW(window, UINT(WM_CLOSE), WindowsApplicationIdentity.explicitCloseRequest, 0)
      default:
        return false
      }
      return true
    }

    static func updateStatus(
      connectionLabel: String,
      runningTasks: Int,
      pendingApprovals: Int
    ) {
      let tooltip = statusTooltip(
        connectionLabel: connectionLabel,
        runningTasks: runningTasks,
        pendingApprovals: pendingApprovals
      )
      guard tooltip != currentTooltip, var data = trayData else { return }
      data.uFlags = UINT(trayNIFTip)
      copyTip(tooltip, into: &data)
      guard Shell_NotifyIconW(trayNIMModify, &data) else { return }
      currentTooltip = tooltip
      trayData = data
    }

    static func statusTooltip(
      connectionLabel: String,
      runningTasks: Int,
      pendingApprovals: Int
    ) -> String {
      [
        "Codex Bridge · \(connectionLabel)",
        "正在运行 \(max(0, runningTasks)) 个任务",
        "等待处理 \(max(0, pendingApprovals)) 项安全审批",
      ].joined(separator: "\n")
    }

    static func removeTrayIcon() {
      if var data = trayData {
        _ = Shell_NotifyIconW(trayNIMDelete, &data)
      }
      trayData = nil
      currentTooltip = "Codex Bridge"
    }

    private static func showContextMenu(for window: HWND?) {
      guard let window, let menu = CreatePopupMenu() else { return }
      defer { _ = DestroyMenu(menu) }

      appendMenuItem(menu, id: MenuCommand.openWorkbench, title: "打开工作台")
      appendMenuItem(menu, id: MenuCommand.openMainWindow, title: "打开主窗口")
      appendMenuItem(menu, id: MenuCommand.refresh, title: "立即刷新状态")
      _ = AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
      appendMenuItem(menu, id: MenuCommand.exit, title: "退出应用程序")

      var position = POINT()
      guard GetCursorPos(&position) else { return }
      _ = SetForegroundWindow(window)
      _ = TrackPopupMenuEx(
        menu,
        UINT(TPM_LEFTALIGN | TPM_BOTTOMALIGN | TPM_RIGHTBUTTON),
        position.x,
        position.y,
        window,
        nil
      )
      if var data = trayData {
        _ = Shell_NotifyIconW(trayNIMSetFocus, &data)
      }
    }

    private static func appendMenuItem(_ menu: HMENU, id: Int, title: String) {
      title.withCString(encodedAs: UTF16.self) { titlePointer in
        _ = AppendMenuW(menu, UINT(MF_STRING), UINT_PTR(id), titlePointer)
      }
    }

    static func restore(_ window: HWND?) {
      activate(window)
    }

    private static func activate(_ window: HWND?) {
      _ = ShowWindow(window, SW_SHOW)
      _ = ShowWindow(window, SW_RESTORE)
      _ = SetForegroundWindow(window)
    }

    private static func installTrayIcon(on window: HWND?) {
      guard let window else { return }
      var data = NOTIFYICONDATAW()
      data.cbSize = DWORD(MemoryLayout<NOTIFYICONDATAW>.size)
      data.hWnd = window
      data.uID = trayIconID
      data.uFlags = UINT(trayNIFMessage | trayNIFIcon | trayNIFTip)
      data.uCallbackMessage = trayCallbackMessage
      data.hIcon = WindowsApplicationIcon.load(width: 16, height: 16)
      copyTip(currentTooltip, into: &data)
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
