#if os(Windows)
  import Foundation
  import WinSDK

  final class WindowsChatWebView: @unchecked Sendable {
    enum State: Equatable, Sendable {
      case unsupported
      case loading
      case active
      case failed
    }

    static let chatURL = "https://chatgpt.com"
    private static let resumeURLDefaultsKey = "chatBrowserResumeURL"

    private let lock = NSLock()
    private var snapshot = Snapshot(
      state: .loading,
      errorDetail: nil,
      canGoBack: false,
      canGoForward: false,
      currentURL: WindowsChatWebView.storedResumeURL()
    )
    private var worker: WindowsWebViewThread?

    var state: State {
      lock.withLock { snapshot.state }
    }

    var errorDetail: String? {
      lock.withLock { snapshot.errorDetail }
    }

    var canGoBack: Bool {
      lock.withLock { snapshot.canGoBack }
    }

    var canGoForward: Bool {
      lock.withLock { snapshot.canGoForward }
    }

    var currentURL: String? {
      lock.withLock { snapshot.currentURL }
    }

    func attach(
      to window: HWND?,
      onStateChanged: (@Sendable (State) -> Void)? = nil,
      onNavigationChanged: (@Sendable (Bool, Bool) -> Void)? = nil
    ) {
      guard let window else { return }
      let initialURL = currentURL ?? Self.chatURL
      let next = WindowsWebViewThread(
        parentWindow: window,
        configuration: .chatBrowser(initialURL: initialURL),
        updateState: { [weak self] state, detail in
          self?.store(state: state, errorDetail: detail)
          onStateChanged?(state)
          if state == .active {
            WindowsMainWindow.enqueue(.refreshAll)
          }
        },
        onWebMessage: nil,
        onNavigationChanged: { [weak self] canGoBack, canGoForward, currentURL in
          self?.storeNavigation(
            canGoBack: canGoBack,
            canGoForward: canGoForward,
            currentURL: currentURL
          )
          onNavigationChanged?(canGoBack, canGoForward)
        }
      )
      guard
        lock.withLock({
          guard worker == nil else { return false }
          worker = next
          return true
        })
      else { return }
      next.start()
    }

    func resize(to bounds: RECT) {
      lock.withLock { worker }?.resize(to: bounds)
    }

    func setVisible(_ visible: Bool) {
      lock.withLock { worker }?.setVisible(visible)
    }

    func bringToTop() {
      lock.withLock { worker }?.bringToTop()
    }

    func goBack() {
      lock.withLock { worker }?.goBack()
    }

    func goForward() {
      lock.withLock { worker }?.goForward()
    }

    func reload() {
      lock.withLock { worker }?.reload()
    }

    func beginShutdown(notifying window: HWND, message: UINT) -> Bool {
      lock.withLock { worker }?.beginShutdown(notifying: window, message: message) ?? false
    }

    func shutdown() {
      let active = lock.withLock { () -> WindowsWebViewThread? in
        defer { worker = nil }
        return worker
      }
      active?.shutdown()
    }

    private func store(state: State, errorDetail: String?) {
      lock.withLock {
        snapshot = Snapshot(
          state: state,
          errorDetail: errorDetail,
          canGoBack: snapshot.canGoBack,
          canGoForward: snapshot.canGoForward,
          currentURL: snapshot.currentURL
        )
      }
    }

    private func storeNavigation(
      canGoBack: Bool,
      canGoForward: Bool,
      currentURL: String?
    ) {
      let safeURL = Self.validatedChatURL(currentURL)
      lock.withLock {
        snapshot = Snapshot(
          state: snapshot.state,
          errorDetail: snapshot.errorDetail,
          canGoBack: canGoBack,
          canGoForward: canGoForward,
          currentURL: safeURL ?? snapshot.currentURL
        )
      }
      if let safeURL {
        UserDefaults.standard.set(safeURL, forKey: Self.resumeURLDefaultsKey)
      }
    }

    private static func storedResumeURL() -> String? {
      validatedChatURL(UserDefaults.standard.string(forKey: resumeURLDefaultsKey))
    }

    private static func validatedChatURL(_ value: String?) -> String? {
      guard let value, let url = URL(string: value),
        url.scheme?.lowercased() == "https",
        url.host?.lowercased() == "chatgpt.com"
      else { return nil }
      return url.absoluteString
    }

    private struct Snapshot {
      let state: State
      let errorDetail: String?
      let canGoBack: Bool
      let canGoForward: Bool
      let currentURL: String?
    }
  }
#endif
