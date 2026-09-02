#if os(Windows)
  import Foundation
  import WinSDK

  enum WindowLayout {
    static let navigationWidth = 220
    static let inspectorIdealWidth = 400
    static let inspectorMinimumWidth = 280
    static let windowWidth = 1180
    static let windowHeight = 760
  }

  enum WindowsMainWindow {
    private static let windowClassName = WindowsApplicationIdentity.mainWindowClassName
    private static let windowTitle = "Codex Bridge"
    private static let defaultPosition = Int32(bitPattern: 0x8000_0000)
    private static let standardResourceID = 32_512
    private static let timerID: UINT_PTR = 1
    private static let timerIntervalMs: UINT = 250
    private static let chatWebViewStoppedMessage = UINT(WM_APP + 40)
    private static let desktopWebViewStoppedMessage = UINT(WM_APP + 41)

    private static let commandLock = NSLock()
    nonisolated(unsafe) private static var pendingCommands: [MainWindowCommand] = []
    nonisolated(unsafe) static var selectedPage = WindowsMainPage.overview
    nonisolated(unsafe) static var chatBounds = RECT()
    nonisolated(unsafe) private static var waitingForWebViewShutdown = false
    nonisolated(unsafe) private static var pendingWebViewShutdownCount = 0
    nonisolated(unsafe) static var sharedOverviewPresented = false
    nonisolated(unsafe) static var chat: WindowsChatWebView?
    nonisolated(unsafe) static var desktopUI: WindowsDesktopUIWebView?
    nonisolated(unsafe) static var window: HWND?

    static func create() -> HWND? {
      WindowsUIFoundation.initialize()
      let instance = GetModuleHandleW(nil)!
      registerWindowClass(instance)
      let created = createWindow(instance: instance)
      guard let window = created else {
        showCreationFailure(GetLastError())
        return nil
      }
      self.window = window
      WindowsNavigationSidebar.create(in: window, instance: instance)
      WindowsPageHeader.create(in: window, instance: instance)
      WindowsOverviewPane.create(in: window, instance: instance)
      WindowsTaskInspector.create(in: window, instance: instance)
      WindowsBrowserToolbar.create(in: window, instance: instance)
      WindowsEmbeddedPages.prepare(in: window)
      WindowsMainWindowChrome.install(on: window)
      _ = SetTimer(window, timerID, timerIntervalMs, nil)
      selectPage(.overview)
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

    static func currentPage() -> WindowsMainPage { selectedPage }

    static func workbenchChatBounds() -> RECT { chatBounds }

    static func takePendingCommands() -> [MainWindowCommand] {
      commandLock.lock()
      defer { commandLock.unlock() }
      let commands = pendingCommands
      pendingCommands.removeAll()
      return commands
    }

    static func selectPage(_ page: WindowsMainPage) {
      selectedPage = page
      WindowsNavigationSidebar.select(page)
      WindowsPageHeader.apply(page: page)
      WindowsOverviewPane.setVisible(page == .overview)
      WindowsTaskInspector.setVisible(page == .workbench)
      WindowsTaskInspector.setChatPlaceholderPageVisible(page == .workbench)
      WindowsBrowserToolbar.setVisible(page == .workbench)
      WindowsEmbeddedPages.select(page)
      chat?.setVisible(page == .workbench)
      applySurfaceVisibility()
      layout()
    }

    static func refreshSurfaceVisibility() {
      if applySurfaceVisibility() { layout() }
    }

    static func updateNavigation(
      workbench: WindowsWorkbenchDisplay,
      management: WindowsManagementDisplay
    ) {
      WindowsNavigationSidebar.update(
        state: workbench.connectionState,
        taskCount: workbench.taskCount,
        approvalCount: workbench.pendingApprovalCount,
        projectCount: management.project.rows.count
      )
      if selectedPage == .connections {
        WindowsPageHeader.apply(
          page: .connections,
          statusDetail:
            "本地 MCP：\(workbench.mcpAddress) · \(management.availableAgentCount) 个可用 Agent"
        )
      }
    }

    static func updateOverview(
      workbench: WindowsWorkbenchDisplay,
      management: WindowsManagementDisplay
    ) {
      WindowsOverviewPane.apply(
        WindowsOverviewDisplay(
          connectionState: workbench.connectionState,
          runningTaskCount: workbench.runningTaskCount,
          pendingApprovalCount: workbench.pendingApprovalCount,
          projectCount: management.project.rows.count,
          agentCount: management.availableAgentCount,
          taskCount: workbench.taskCount,
          mcpAddress: workbench.mcpAddress,
          recentTaskRows: Array(workbench.recentTaskRows.prefix(4)),
          detailText: workbench.detailText
        )
      )
    }

    static func setStatusText(_ text: String) {
      WindowsTaskInspector.setStatusText(text)
    }

    static func setTaskRows(_ rows: [String], selectedIndex: Int?) {
      WindowsTaskInspector.setTaskRows(rows, selectedIndex: selectedIndex)
    }

    static func setChatPlaceholder(_ text: String?) {
      WindowsTaskInspector.setChatPlaceholder(text)
      WindowsTaskInspector.setChatPlaceholderPageVisible(selectedPage == .workbench)
    }

    static func handleMessage(
      _ window: HWND?, _ message: UINT, _ wParam: WPARAM, _ lParam: LPARAM
    ) -> LRESULT {
      switch message {
      case UINT(WM_COMMAND):
        let command =
          WindowsNavigationSidebar.command(for: wParam)
          ?? WindowsPageHeader.command(for: wParam)
          ?? WindowsOverviewPane.command(for: wParam)
          ?? WindowsBrowserToolbar.command(for: wParam)
          ?? WindowsTaskInspector.command(for: wParam)
          ?? WindowsEmbeddedPageTabs.command(for: wParam)
        if let command { enqueue(command) }
        return 0
      case UINT(WM_SIZE):
        if wParam == WPARAM(SIZE_MINIMIZED) {
          _ = ShowWindow(window, SW_HIDE)
        } else {
          layout()
        }
        return 0
      case WindowsMainWindowChrome.trayCallbackMessage:
        _ = WindowsMainWindowChrome.handleTrayMessage(lParam, window: window)
        return 0
      case UINT(WM_CLOSE):
        requestClose(window)
        return 0
      case chatWebViewStoppedMessage:
        chat?.shutdown()
        finishWebViewShutdown(window)
        return 0
      case desktopWebViewStoppedMessage:
        desktopUI?.shutdown()
        finishWebViewShutdown(window)
        return 0
      case UINT(WM_DESTROY):
        WindowsMainWindowChrome.removeTrayIcon()
        WindowsUIFoundation.shutdown()
        waitingForWebViewShutdown = false
        pendingWebViewShutdownCount = 0
        sharedOverviewPresented = false
        desktopUI = nil
        Self.window = nil
        PostQuitMessage(0)
        return 0
      default:
        return DefWindowProcW(window, message, wParam, lParam)
      }
    }

    private static func requestClose(_ window: HWND?) {
      guard !waitingForWebViewShutdown else { return }
      guard let window else { return }
      var shutdownCount = 0
      if chat?.beginShutdown(notifying: window, message: chatWebViewStoppedMessage) == true {
        shutdownCount += 1
      }
      if desktopUI?.beginShutdown(notifying: window, message: desktopWebViewStoppedMessage) == true
      {
        shutdownCount += 1
      }
      if shutdownCount > 0 {
        waitingForWebViewShutdown = true
        pendingWebViewShutdownCount = shutdownCount
        _ = EnableWindow(window, false)
        return
      }
      _ = DestroyWindow(window)
    }

    private static func finishWebViewShutdown(_ window: HWND?) {
      pendingWebViewShutdownCount = max(0, pendingWebViewShutdownCount - 1)
      if pendingWebViewShutdownCount == 0 { _ = DestroyWindow(window) }
    }

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
        windowClass.hIcon = LoadIconW(nil, resourcePointer(standardResourceID))
        windowClass.hCursor = LoadCursorW(nil, resourcePointer(standardResourceID))
        windowClass.hbrBackground = GetSysColorBrush(COLOR_WINDOW)
        windowClass.lpszClassName = className
        _ = RegisterClassW(&windowClass)
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
