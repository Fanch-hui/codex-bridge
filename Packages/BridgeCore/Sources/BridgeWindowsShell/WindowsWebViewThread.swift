#if os(Windows)
  import Foundation
  import WinSDK

  final class WindowsWebViewThread: @unchecked Sendable {
    typealias StateUpdate = @Sendable (WindowsChatWebView.State, String?) -> Void

    private enum Message {
      static let synchronize = UINT(WM_APP + 1)
      static let goBack = UINT(WM_APP + 2)
      static let goForward = UINT(WM_APP + 3)
      static let reload = UINT(WM_APP + 4)
      static let postWebMessage = UINT(WM_APP + 5)
    }

    typealias NavigationUpdate = @Sendable (Bool, Bool) -> Void

    let parentWindow: HWND
    private let initialURL: String
    let profileName: String
    let configuration: WindowsWebViewConfiguration
    private let updateState: StateUpdate
    private let onWebMessage: (@Sendable (String) -> Void)?
    private let onNavigationChanged: NavigationUpdate?
    let lock = NSLock()
    let finished = CreateEventW(nil, true, false, nil)
    var threadID: DWORD = 0
    private var pendingBounds = RECT()
    private var pendingVisible = false
    var stopping = false
    var completed = false
    var shutdownNotification: (window: HWND, message: UINT)?

    var loaderModule: HMODULE?
    var environment: UnsafeMutableRawPointer?
    var controller: UnsafeMutableRawPointer?
    var webView: UnsafeMutableRawPointer?
    var webMessageHandler: UnsafeMutableRawPointer?
    var webMessageToken = WebView2EventRegistrationToken()
    var hasWebMessageToken = false
    var historyChangedHandler: UnsafeMutableRawPointer?
    var historyChangedToken = WebView2EventRegistrationToken()
    var hasHistoryChangedToken = false
    var navigationCompletedHandler: UnsafeMutableRawPointer?
    var navigationCompletedToken = WebView2EventRegistrationToken()
    var hasNavigationCompletedToken = false
    private var pendingWebMessage: String?

    convenience init(
      parentWindow: HWND,
      updateState: @escaping StateUpdate,
      onNavigationChanged: NavigationUpdate? = nil
    ) {
      self.init(
        parentWindow: parentWindow,
        configuration: .chatBrowser(),
        updateState: updateState,
        onWebMessage: nil,
        onNavigationChanged: onNavigationChanged
      )
    }

    convenience init(
      parentWindow: HWND,
      initialURL: String,
      profileName: String,
      updateState: @escaping StateUpdate,
      onWebMessage: (@Sendable (String) -> Void)?
    ) {
      let config =
        profileName == "DesktopUI"
        ? WindowsWebViewConfiguration.desktopUI(initialURL: initialURL)
        : WindowsWebViewConfiguration.chatBrowser(initialURL: initialURL)
      self.init(
        parentWindow: parentWindow,
        configuration: config,
        updateState: updateState,
        onWebMessage: onWebMessage,
        onNavigationChanged: nil
      )
    }

    init(
      parentWindow: HWND,
      configuration: WindowsWebViewConfiguration,
      updateState: @escaping StateUpdate,
      onWebMessage: (@Sendable (String) -> Void)?,
      onNavigationChanged: NavigationUpdate? = nil
    ) {
      self.parentWindow = parentWindow
      self.configuration = configuration
      self.initialURL = configuration.initialURL
      self.profileName = configuration.profileName
      self.updateState = updateState
      self.onWebMessage = onWebMessage
      self.onNavigationChanged = onNavigationChanged
    }

    deinit {
      if let finished { _ = CloseHandle(finished) }
    }

    func start() {
      Thread.detachNewThread { [self] in run() }
    }

    func resize(to bounds: RECT) {
      lock.withLock { pendingBounds = bounds }
      post(Message.synchronize)
    }

    func setVisible(_ visible: Bool) {
      lock.withLock { pendingVisible = visible }
      post(Message.synchronize)
    }

    func goBack() { post(Message.goBack) }
    func goForward() { post(Message.goForward) }
    func reload() { post(Message.reload) }

    func postWebMessageAsJSON(_ message: String) {
      lock.withLock { pendingWebMessage = message }
      post(Message.postWebMessage)
    }

    func beginShutdown(notifying window: HWND, message: UINT) -> Bool {
      let target = lock.withLock { () -> DWORD? in
        guard !completed else { return nil }
        stopping = true
        shutdownNotification = (window, message)
        return threadID
      }
      guard let target else { return false }
      if target != 0 { _ = PostThreadMessageW(target, UINT(WM_QUIT), 0, 0) }
      return true
    }

    func shutdown() {
      let target = lock.withLock { () -> DWORD in
        stopping = true
        return threadID
      }
      if target != 0 { _ = PostThreadMessageW(target, UINT(WM_QUIT), 0, 0) }
      if let finished { _ = WaitForSingleObject(finished, 5_000) }
    }

    private func run() {
      let comInitialization = CoInitializeEx(nil, DWORD(0x2))
      defer {
        releaseInterfaces()
        if let loaderModule { _ = FreeLibrary(loaderModule) }
        if comInitialization >= 0 { CoUninitialize() }
        complete()
      }
      guard comInitialization >= 0 else {
        updateState(
          .unsupported,
          "无法创建 WebView2 所需的 STA COM 线程（\(hresult(comInitialization))）。"
        )
        return
      }
      var message = MSG()
      _ = PeekMessageW(&message, nil, 0, 0, UINT(PM_NOREMOVE))
      let shouldStop = lock.withLock { () -> Bool in
        threadID = GetCurrentThreadId()
        return stopping
      }
      guard !shouldStop else { return }
      createEnvironment()
      while GetMessageW(&message, nil, 0, 0) {
        handle(message.message)
        _ = TranslateMessage(&message)
        _ = DispatchMessageW(&message)
      }
    }

    private func createEnvironment() {
      guard let loader = loadLoader() else {
        updateState(.unsupported, "未找到随应用安装的 WebView2Loader.dll。")
        return
      }
      guard let create = loadCreateFunction(loader) else {
        _ = FreeLibrary(loader)
        updateState(.unsupported, "WebView2Loader.dll 缺少环境创建入口。")
        return
      }
      loaderModule = loader
      guard let userDataFolder = userDataFolderPath() else {
        updateState(.failed, "无法确定 WebView2 用户数据目录。")
        return
      }
      ensureDirectoryExists(userDataFolder)
      let handler = webView2CompletionHandler { [weak self] errorCode, environment in
        self?.environmentCreated(errorCode: errorCode, environment: environment)
      }
      let result = userDataFolder.withCString(encodedAs: UTF16.self) { folder in
        create(nil, folder, nil, handler)
      }
      _ = webView2Release(handler)
      if result != webview2SOK {
        updateState(.failed, "创建 WebView2 环境失败（\(hresult(result))）。")
      }
    }

    private func environmentCreated(errorCode: HRESULT, environment: UnsafeMutableRawPointer?) {
      guard errorCode == webview2SOK, let environment else {
        updateState(.failed, "WebView2 环境初始化失败（\(hresult(errorCode))）。")
        return
      }
      self.environment = environment
      webView2AddRef(environment)
      let createController: WebView2CreateControllerFn = webView2Method(
        environment,
        WebView2Slot.environmentCreateController,
        as: WebView2CreateControllerFn.self
      )
      let handler = webView2CompletionHandler { [weak self] errorCode, controller in
        self?.controllerCreated(errorCode: errorCode, controller: controller)
      }
      let result = createController(environment, parentWindow, handler)
      _ = webView2Release(handler)
      if result != webview2SOK {
        updateState(.failed, "创建 WebView2 Controller 失败（\(hresult(result))）。")
      }
    }

    private func controllerCreated(errorCode: HRESULT, controller: UnsafeMutableRawPointer?) {
      guard errorCode == webview2SOK, let controller else {
        updateState(.failed, "WebView2 Controller 初始化失败（\(hresult(errorCode))）。")
        return
      }
      self.controller = controller
      webView2AddRef(controller)

      if let color = configuration.defaultBackgroundColor {
        var controller2Pointer: UnsafeMutableRawPointer?
        let qi: WebView2QueryInterfaceFn = webView2Method(
          controller, 0, as: WebView2QueryInterfaceFn.self
        )
        var iid = iidController2
        if qi(controller, &iid, &controller2Pointer) == webview2SOK,
          let controller2 = controller2Pointer
        {
          defer { _ = webView2Release(controller2) }
          let putColor: WebView2PutColorFn = webView2Method(
            controller2, WebView2Slot.controller2PutDefaultBackgroundColor,
            as: WebView2PutColorFn.self
          )
          _ = putColor(
            controller2,
            COREWEBVIEW2_COLOR(a: color.a, r: color.r, g: color.g, b: color.b).rawValue
          )
        }
      }

      synchronizeController()
      var pointer: UnsafeMutableRawPointer?
      let getWebView: WebView2GetCoreWebView2Fn = webView2Method(
        controller,
        WebView2Slot.controllerGetCoreWebView2,
        as: WebView2GetCoreWebView2Fn.self
      )
      guard getWebView(controller, &pointer) == webview2SOK, let webView = pointer else {
        updateState(.failed, "无法取得 WebView2 浏览器实例。")
        return
      }
      self.webView = webView

      if configuration.hasCustomSettings {
        var settingsPointer: UnsafeMutableRawPointer?
        let getSettings: WebView2GetSettingsFn = webView2Method(
          webView, WebView2Slot.webViewGetSettings, as: WebView2GetSettingsFn.self
        )
        if getSettings(webView, &settingsPointer) == webview2SOK, let settings = settingsPointer {
          defer { _ = webView2Release(settings) }
          if configuration.disableDefaultContextMenu {
            let put: WebView2PutBoolFn = webView2Method(
              settings, WebView2Slot.settingsPutAreDefaultContextMenusEnabled,
              as: WebView2PutBoolFn.self
            )
            _ = put(settings, false)
          }
          if configuration.disableStatusBar {
            let put: WebView2PutBoolFn = webView2Method(
              settings, WebView2Slot.settingsPutIsStatusBarEnabled,
              as: WebView2PutBoolFn.self
            )
            _ = put(settings, false)
          }
          if configuration.disableDevTools {
            let put: WebView2PutBoolFn = webView2Method(
              settings, WebView2Slot.settingsPutAreDevToolsEnabled,
              as: WebView2PutBoolFn.self
            )
            _ = put(settings, false)
          }
          if configuration.disableZoomControl {
            let put: WebView2PutBoolFn = webView2Method(
              settings, WebView2Slot.settingsPutIsZoomControlEnabled,
              as: WebView2PutBoolFn.self
            )
            _ = put(settings, false)
          }
        }
      }

      if onWebMessage != nil {
        let handler = webView2WebMessageHandler { [weak self] _, args in
          guard let json = webView2ReadWebMessageJSON(args) else { return }
          self?.onWebMessage?(json)
        }
        var token = WebView2EventRegistrationToken()
        let addMessageHandler: WebView2AddWebMessageReceivedFn = webView2Method(
          webView, WebView2Slot.webViewAddWebMessageReceived,
          as: WebView2AddWebMessageReceivedFn.self
        )
        let result = addMessageHandler(webView, handler, &token)
        if result != webview2SOK {
          _ = webView2Release(handler)
          updateState(.failed, "无法接收 Desktop UI 命令（\(hresult(result))）。")
          return
        }
        webMessageHandler = handler
        webMessageToken = token
        hasWebMessageToken = true
      }

      if onNavigationChanged != nil {
        let historyHandler = webView2HistoryChangedHandler { [weak self] _, _ in
          self?.syncNavigationState()
        }
        var hToken = WebView2EventRegistrationToken()
        let addHistory: WebView2AddEventHandlerFn = webView2Method(
          webView, WebView2Slot.webViewAddHistoryChanged,
          as: WebView2AddEventHandlerFn.self
        )
        if addHistory(webView, historyHandler, &hToken) == webview2SOK {
          historyChangedHandler = historyHandler
          historyChangedToken = hToken
          hasHistoryChangedToken = true
        } else {
          _ = webView2Release(historyHandler)
        }

        let navHandler = webView2NavigationCompletedHandler { [weak self] _, _ in
          self?.syncNavigationState()
        }
        var nToken = WebView2EventRegistrationToken()
        let addNav: WebView2AddEventHandlerFn = webView2Method(
          webView, WebView2Slot.webViewAddNavigationCompleted,
          as: WebView2AddEventHandlerFn.self
        )
        if addNav(webView, navHandler, &nToken) == webview2SOK {
          navigationCompletedHandler = navHandler
          navigationCompletedToken = nToken
          hasNavigationCompletedToken = true
        } else {
          _ = webView2Release(navHandler)
        }
      }

      let navigate: WebView2NavigateFn = webView2Method(
        webView,
        WebView2Slot.webViewNavigate,
        as: WebView2NavigateFn.self
      )
      _ = initialURL.withCString(encodedAs: UTF16.self) {
        navigate(webView, $0)
      }
      updateState(.active, nil)
    }

    func syncNavigationState() {
      guard let webView else { return }
      var canGoBackInt: Int32 = 0
      var canGoForwardInt: Int32 = 0
      let getCanGoBack: WebView2GetBoolFn = webView2Method(
        webView, WebView2Slot.webViewGetCanGoBack, as: WebView2GetBoolFn.self
      )
      let getCanGoForward: WebView2GetBoolFn = webView2Method(
        webView, WebView2Slot.webViewGetCanGoForward, as: WebView2GetBoolFn.self
      )
      _ = getCanGoBack(webView, &canGoBackInt)
      _ = getCanGoForward(webView, &canGoForwardInt)
      let canGoBack = canGoBackInt != 0
      let canGoForward = canGoForwardInt != 0
      onNavigationChanged?(canGoBack, canGoForward)
    }

    private func handle(_ message: UINT) {
      switch message {
      case Message.synchronize: synchronizeController()
      case Message.goBack: runAction(WebView2Slot.webViewGoBack)
      case Message.goForward: runAction(WebView2Slot.webViewGoForward)
      case Message.reload: runAction(WebView2Slot.webViewReload)
      case Message.postWebMessage: postPendingWebMessage()
      default: break
      }
    }

    private func postPendingWebMessage() {
      guard let webView else { return }
      let message = lock.withLock { () -> String? in
        defer { pendingWebMessage = nil }
        return pendingWebMessage
      }
      guard let message else { return }
      let post: WebView2PostWebMessageAsJSONFn = webView2Method(
        webView, WebView2Slot.webViewPostWebMessageAsJSON,
        as: WebView2PostWebMessageAsJSONFn.self
      )
      _ = message.withCString(encodedAs: UTF16.self) { post(webView, $0) }
    }

    private func synchronizeController() {
      guard let controller else { return }
      let values = lock.withLock { (pendingBounds, pendingVisible) }
      let putBounds: WebView2PutBoundsFn = webView2Method(
        controller, WebView2Slot.controllerPutBounds, as: WebView2PutBoundsFn.self)
      let putVisible: WebView2PutBoolFn = webView2Method(
        controller, WebView2Slot.controllerPutIsVisible, as: WebView2PutBoolFn.self)
      _ = putBounds(controller, values.0)
      _ = putVisible(controller, values.1)
      if values.1 && configuration.purpose == .chatBrowser {
        bringToTop()
      }
    }

    private func runAction(_ slot: Int) {
      guard let webView else { return }
      let action: WebView2ActionFn = webView2Method(webView, slot, as: WebView2ActionFn.self)
      _ = action(webView)
    }

    func post(_ message: UINT) {
      let target = lock.withLock { threadID }
      if target != 0 { _ = PostThreadMessageW(target, message, 0, 0) }
    }

  }
#endif
