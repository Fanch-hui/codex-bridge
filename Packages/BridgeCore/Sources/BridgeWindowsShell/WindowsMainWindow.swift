#if os(Windows)
  import BridgeDesktopUI
  import Foundation
  import WinSDK

  enum WindowLayout {
    static let windowWidth = 1180
    static let windowHeight = 760
  }

  /// Win32 host surface: owns the frame, the command queue and the two WebView2
  /// children. All product pages live in `BridgeDesktopUI`.
  enum WindowsMainWindow {
    private static let windowClassName = WindowsApplicationIdentity.mainWindowClassName
    private static let windowTitle = "Codex Bridge"
    private static let defaultPosition = Int32(bitPattern: 0x8000_0000)
    private static let standardResourceID = 32_512

    private static let commandLock = NSLock()
    private static let browserViewportLock = NSLock()
    nonisolated(unsafe) private static var pendingCommands: [MainWindowCommand] = []
    nonisolated(unsafe) private static var browserViewport: BridgeDesktopBrowserViewport?
    nonisolated(unsafe) static var chatSlotEnabled = false

    /// Mirror of the page the shared UI last rendered; the command loop owns the
    /// request, this value only reports what reached the surface.
    nonisolated(unsafe) static var renderedPage = WindowsMainPage.overview
    nonisolated(unsafe) static var chatBounds = RECT()
    nonisolated(unsafe) static var chat: WindowsChatWebView?
    nonisolated(unsafe) static var desktopUI: WindowsDesktopUIWebView?
    nonisolated(unsafe) static var window: HWND?

    static func create() -> HWND? {
      WindowsUIFoundation.initialize()
      let instance = GetModuleHandleW(nil)!
      registerWindowClass(instance)
      guard let window = createWindow(instance: instance) else {
        showCreationFailure(GetLastError())
        return nil
      }
      self.window = window
      applyDwmAttributes(to: window)
      setWindowIcons(window)
      WindowsMainWindowChrome.install(on: window)
      layout()
      _ = ShowWindow(window, SW_SHOW)
      return window
    }

    static func enqueue(_ command: MainWindowCommand) {
      commandLock.lock()
      pendingCommands.append(command)
      commandLock.unlock()
    }

    static func currentWindow() -> HWND? { window }

    static func currentPage() -> WindowsMainPage { renderedPage }

    static func takePendingCommands() -> [MainWindowCommand] {
      commandLock.lock()
      defer { commandLock.unlock() }
      let commands = pendingCommands
      pendingCommands.removeAll()
      return commands
    }

    static func selectPage(_ page: WindowsMainPage) {
      renderedPage = page
      layout()
    }

    static func setChatSlotEnabled(_ enabled: Bool) {
      guard chatSlotEnabled != enabled else { return }
      chatSlotEnabled = enabled
      layout()
    }

    static func applyBrowserViewport(_ viewport: BridgeDesktopBrowserViewport) {
      browserViewportLock.withLock { browserViewport = viewport }
      WindowsUIThread.shared.enqueue { layout() }
    }

    static func browserViewportSnapshot() -> BridgeDesktopBrowserViewport? {
      browserViewportLock.withLock { browserViewport }
    }

    static func handleMessage(
      _ window: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM
    ) -> LRESULT {
      switch message {
      case UINT(WM_COMMAND):
        if WindowsMainWindowChrome.handleCommand(wParam, window: window) { return 0 }
        return 0
      case UINT(WM_SIZE):
        if wParam == WPARAM(SIZE_MINIMIZED) {
          _ = ShowWindow(window, SW_HIDE)
        } else {
          layout()
        }
        return 0
      case UINT(WM_DPICHANGED):
        if let suggestedRect = UnsafePointer<RECT>(bitPattern: Int(lParam))?.pointee {
          _ = SetWindowPos(
            window,
            nil,
            suggestedRect.left,
            suggestedRect.top,
            suggestedRect.right - suggestedRect.left,
            suggestedRect.bottom - suggestedRect.top,
            UINT(SWP_NOZORDER | SWP_NOACTIVATE)
          )
        }
        layout()
        return 0
      case UINT(WM_GETMINMAXINFO):
        if let minMaxInfo = UnsafeMutablePointer<MINMAXINFO>(bitPattern: Int(lParam)) {
          let dpi = GetDpiForWindow(window)
          let scale = Double(dpi > 0 ? dpi : 96) / 96.0
          minMaxInfo.pointee.ptMinTrackSize.x = Int32(Double(800) * scale)
          minMaxInfo.pointee.ptMinTrackSize.y = Int32(Double(500) * scale)
        }
        return 0
      case WindowsMainWindowChrome.trayCallbackMessage:
        if WindowsMainWindowChrome.handleTrayMessage(lParam, window: window) {
          resynchronizeAfterRestore()
        }
        return 0
      case UINT(WM_CLOSE):
        if wParam == WindowsApplicationIdentity.explicitCloseRequest {
          WindowsMainWindowLifecycle.requestExit(window)
        } else {
          _ = ShowWindow(window, SW_HIDE)
        }
        return 0
      case WindowsMainWindowLifecycle.chatStoppedMessage:
        chat?.shutdown()
        WindowsMainWindowLifecycle.finishWebViewShutdown(window)
        return 0
      case WindowsMainWindowLifecycle.desktopStoppedMessage:
        desktopUI?.shutdown()
        WindowsMainWindowLifecycle.finishWebViewShutdown(window)
        return 0
      case UINT(WM_DESTROY):
        WindowsMainWindowChrome.removeTrayIcon()
        WindowsUIFoundation.shutdown()
        WindowsMainWindowLifecycle.reset()
        desktopUI = nil
        Self.window = nil
        PostQuitMessage(0)
        return 0
      default:
        return DefWindowProcW(window, message, wParam, lParam)
      }
    }

    /// Surfaces the desktop UI once it is live and reports a clear reason when the
    /// host cannot load it, so a broken install never degrades to a silent blank frame.
    static func refreshSurfaces() {
      guard let window else { return }
      desktopUI?.setVisible(desktopUI?.isReady == true)
      WindowsShellFailure.present(desktopFailureText(), in: window)
    }

    /// Re-applies surface bounds after a tray restore, where Win32 does not reliably
    /// raise WM_SIZE for a window that was hidden rather than minimized.
    static func resynchronizeAfterRestore() {
      layout()
      refreshSurfaces()
    }

    static func desktopFailureText() -> String? {
      guard let desktopUI else { return nil }
      guard !desktopUI.isReady else { return nil }
      switch desktopUI.state {
      case .failed, .unsupported:
        return
          "界面无法加载：\(desktopUI.errorDetail ?? "WebView2 运行时不可用")\r\n请安装 Microsoft Edge WebView2 Evergreen 运行时后重试，任务与本地 MCP 服务仍在后台运行。"
      default:
        return desktopUI.loadStalled ? desktopStallText : nil
      }
    }

    private static let desktopStallText =
      "界面未能完成加载：WebView2 已启动，但页面没有响应。\r\n请重新启动 Codex Bridge；如果仍然如此，请修复安装或更新 Microsoft Edge WebView2 Evergreen 运行时。任务与本地 MCP 服务仍在后台运行。"

    private static func createWindow(instance: HINSTANCE?) -> HWND? {
      windowTitle.withCString(encodedAs: UTF16.self) { title in
        windowClassName.withCString(encodedAs: UTF16.self) { className in
          CreateWindowExW(
            0,
            className,
            title,
            DWORD(WS_OVERLAPPEDWINDOW) | DWORD(WS_CLIPCHILDREN),
            defaultPosition,
            defaultPosition,
            Int32(WindowLayout.windowWidth),
            Int32(WindowLayout.windowHeight),
            nil,
            nil,
            instance,
            nil
          )
        }
      }
    }

    private static func registerWindowClass(_ instance: HINSTANCE) {
      windowClassName.withCString(encodedAs: UTF16.self) { className in
        var windowClass = WNDCLASSW()
        windowClass.lpfnWndProc = { window, message, wParam, lParam in
          WindowsMainWindow.handleMessage(window, message, wParam, lParam)
        }
        windowClass.hInstance = instance
        windowClass.hIcon = WindowsApplicationIcon.load()
        windowClass.hCursor = LoadCursorW(nil, resourcePointer(standardResourceID))
        windowClass.hbrBackground = CreateSolidBrush(COLORREF(0x001B_1818))
        windowClass.lpszClassName = className
        _ = RegisterClassW(&windowClass)
      }
    }

    private static func applyDwmAttributes(to window: HWND) {
      var useDarkMode: Int32 = 1
      _ = DwmSetWindowAttribute(
        window,
        DWORD(20),
        &useDarkMode,
        DWORD(MemoryLayout<Int32>.size)
      )
      var cornerPreference: DWORD = 2
      _ = DwmSetWindowAttribute(
        window,
        DWORD(33),
        &cornerPreference,
        DWORD(MemoryLayout<DWORD>.size)
      )
    }

    private static func setWindowIcons(_ window: HWND) {
      if let iconBig = WindowsApplicationIcon.load(width: 32, height: 32) {
        _ = SendMessageW(window, UINT(WM_SETICON), WPARAM(1), LPARAM(Int(bitPattern: iconBig)))
      }
      if let iconSmall = WindowsApplicationIcon.load(width: 16, height: 16) {
        _ = SendMessageW(window, UINT(WM_SETICON), WPARAM(0), LPARAM(Int(bitPattern: iconSmall)))
      }
    }

    private static func showCreationFailure(_ errorCode: DWORD) {
      let message = "无法创建 Codex Bridge 主窗口。Win32 错误：\(errorCode)"
      message.withCString(encodedAs: UTF16.self) { messagePointer in
        windowTitle.withCString(encodedAs: UTF16.self) { titlePointer in
          _ = MessageBoxW(
            nil,
            messagePointer,
            titlePointer,
            UINT(MB_OK) | UINT(MB_ICONERROR)
          )
        }
      }
    }

    private static func resourcePointer(_ id: Int) -> UnsafePointer<WCHAR> {
      UnsafePointer<WCHAR>(bitPattern: id)!
    }
  }
#endif
