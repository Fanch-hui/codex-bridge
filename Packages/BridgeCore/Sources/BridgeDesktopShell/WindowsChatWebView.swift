#if os(Windows)
  import BridgeServiceAppCore
  import Foundation
  import WinSDK

  final class WindowsChatWebView: @unchecked Sendable {
    enum State: Equatable, Sendable {
      case unsupported
      case loading
      case active
      case failed
    }

    static let chatURL = ChatBrowserSite.chatGPT.homeURL.absoluteString

    private let lock = NSLock()
    private let preferences: ChatBrowserPreferences
    private var selectedSite: ChatBrowserSite
    private var snapshots: [ChatBrowserSite: Snapshot] = [:]
    private var workers: [ChatBrowserSite: WindowsWebViewThread] = [:]
    private var parentWindow: HWND?
    private var bounds = RECT()
    private var visible = false
    private var lowMemoryUsage = false
    private var stopping = false

    init(defaults: UserDefaults = .standard) {
      preferences = ChatBrowserPreferences(defaults: defaults)
      selectedSite = preferences.selectedSite
    }

    var site: ChatBrowserSite { lock.withLock { selectedSite } }
    var state: State { lock.withLock { currentSnapshot.state } }
    var errorDetail: String? { lock.withLock { currentSnapshot.errorDetail } }
    var canGoBack: Bool { lock.withLock { currentSnapshot.canGoBack } }
    var canGoForward: Bool { lock.withLock { currentSnapshot.canGoForward } }
    var currentURL: String? { lock.withLock { currentSnapshot.currentURL } }

    func attach(to window: HWND?) {
      guard let window else { return }
      let next = lock.withLock { () -> WindowsWebViewThread? in
        guard parentWindow == nil, !stopping else { return nil }
        parentWindow = window
        return createWorker(for: selectedSite)
      }
      next?.start()
    }

    func selectSite(_ site: ChatBrowserSite) {
      let next = lock.withLock { () -> WindowsWebViewThread? in
        guard !stopping, selectedSite != site else { return nil }
        selectedSite = site
        preferences.selectedSite = site
        let next = createWorker(for: site)
        applyWorkerLayout()
        return next
      }
      next?.start()
    }

    func resize(to bounds: RECT) {
      lock.withLock {
        self.bounds = bounds
        applyWorkerLayout()
      }
    }

    func setVisible(_ visible: Bool) {
      lock.withLock {
        self.visible = visible
        applyWorkerLayout()
      }
    }

    func setLowMemoryUsage(_ low: Bool) {
      lock.withLock {
        lowMemoryUsage = low
        applyWorkerLayout()
      }
    }

    func applyLayout(to bounds: RECT, visible: Bool) {
      lock.withLock {
        self.bounds = bounds
        self.visible = visible
        applyWorkerLayout()
      }
    }

    func goBack() { lock.withLock { workers[selectedSite] }?.goBack() }
    func goForward() { lock.withLock { workers[selectedSite] }?.goForward() }
    func reload() { lock.withLock { workers[selectedSite] }?.reload() }

    func beginShutdown(notifying window: HWND, message: UINT) -> Int {
      let active = lock.withLock { () -> [WindowsWebViewThread] in
        stopping = true
        return Array(workers.values)
      }
      return active.reduce(0) { count, worker in
        count + (worker.beginShutdown(notifying: window, message: message) ? 1 : 0)
      }
    }

    func shutdown() {
      let active = lock.withLock { () -> [WindowsWebViewThread] in
        stopping = true
        defer { workers.removeAll() }
        return Array(workers.values)
      }
      for worker in active { worker.shutdown() }
    }

    private var currentSnapshot: Snapshot {
      snapshots[selectedSite] ?? Snapshot(url: preferences.resumeURL(for: selectedSite))
    }

    private func createWorker(for site: ChatBrowserSite) -> WindowsWebViewThread? {
      guard workers[site] == nil, let parentWindow else { return nil }
      let initialURL = preferences.resumeURL(for: site)
      snapshots[site] = Snapshot(url: initialURL)
      let worker = WindowsWebViewThread(
        parentWindow: parentWindow,
        configuration: .chatBrowser(site: site, initialURL: initialURL.absoluteString),
        updateState: { [weak self] state, detail in
          self?.store(state: state, errorDetail: detail, for: site)
        },
        onWebMessage: nil,
        onNavigationChanged: { [weak self] canGoBack, canGoForward, currentURL in
          self?.storeNavigation(
            canGoBack: canGoBack, canGoForward: canGoForward,
            currentURL: currentURL, for: site
          )
        }
      )
      workers[site] = worker
      worker.applyLayout(to: bounds, visible: visible && site == selectedSite)
      worker.setLowMemoryUsage(lowMemoryUsage || site != selectedSite)
      return worker
    }

    private func applyWorkerLayout() {
      for (site, worker) in workers {
        worker.applyLayout(to: bounds, visible: visible && site == selectedSite)
        worker.setLowMemoryUsage(lowMemoryUsage || site != selectedSite)
      }
    }

    private func store(state: State, errorDetail: String?, for site: ChatBrowserSite) {
      lock.withLock {
        guard var snapshot = snapshots[site] else { return }
        snapshot.state = state
        snapshot.errorDetail = errorDetail
        snapshots[site] = snapshot
      }
    }

    private func storeNavigation(
      canGoBack: Bool, canGoForward: Bool, currentURL: String?, for site: ChatBrowserSite
    ) {
      let safeURL = site.validatedURL(currentURL.flatMap(URL.init(string:)))
      lock.withLock {
        guard var snapshot = snapshots[site] else { return }
        snapshot.canGoBack = canGoBack
        snapshot.canGoForward = canGoForward
        if let safeURL {
          snapshot.currentURL = safeURL.absoluteString
          preferences.remember(safeURL, for: site)
        }
        snapshots[site] = snapshot
      }
    }

    private struct Snapshot {
      var state = State.loading
      var errorDetail: String?
      var canGoBack = false
      var canGoForward = false
      var currentURL: String?

      init(url: URL) { currentURL = url.absoluteString }
    }
  }
#endif
