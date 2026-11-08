#if os(Windows)
  import BridgeServiceAppCore
  import Foundation
  import WinSDK

  protocol WindowsChatBrowserWorker: AnyObject, Sendable {
    func start()
    func applyLayout(to bounds: RECT, visible: Bool)
    func setLowMemoryUsage(_ low: Bool)
    func goBack()
    func goForward()
    func reload()
    func beginShutdown(notifying window: HWND, message: UINT) -> Bool
    func shutdown()
    func shutdown(onCompletion: @escaping @Sendable () -> Void)
  }

  extension WindowsWebViewThread: WindowsChatBrowserWorker {}

  final class WindowsChatWebView: @unchecked Sendable {
    enum State: Equatable, Sendable {
      case unsupported
      case loading
      case active
      case failed
    }

    static let chatURL = ChatBrowserSite.chatGPT.homeURL.absoluteString

    typealias WorkerFactory =
      @Sendable (
        HWND, WindowsWebViewConfiguration, @escaping WindowsWebViewThread.StateUpdate,
        @escaping WindowsWebViewThread.NavigationUpdate
      ) -> any WindowsChatBrowserWorker

    private let lock = NSLock()
    private let preferences: ChatBrowserPreferences
    private let workerFactory: WorkerFactory
    private var selectedSite: ChatBrowserSite
    private var snapshots: [ChatBrowserSite: Snapshot] = [:]
    private var workers: [ChatBrowserSite: any WindowsChatBrowserWorker] = [:]
    private var closingWorkers: [ChatBrowserSite: any WindowsChatBrowserWorker] = [:]
    private var generations: [ChatBrowserSite: UInt64] = [:]
    private var nextGeneration: UInt64 = 0
    private var parentWindow: HWND?
    private var bounds = RECT()
    private var visible = false
    private var lowMemoryUsage = false
    private var enabled: Bool
    private var stopping = false

    init(
      defaults: UserDefaults = .standard,
      workerFactory: @escaping WorkerFactory = { window, configuration, state, navigation in
        WindowsWebViewThread(
          parentWindow: window, configuration: configuration,
          updateState: state, onWebMessage: nil, onNavigationChanged: navigation)
      }
    ) {
      preferences = ChatBrowserPreferences(defaults: defaults)
      selectedSite = preferences.selectedSite
      enabled = preferences.isEnabled
      self.workerFactory = workerFactory
    }

    var site: ChatBrowserSite { lock.withLock { selectedSite } }
    var state: State { lock.withLock { currentSnapshot.state } }
    var errorDetail: String? { lock.withLock { currentSnapshot.errorDetail } }
    var canGoBack: Bool { lock.withLock { currentSnapshot.canGoBack } }
    var canGoForward: Bool { lock.withLock { currentSnapshot.canGoForward } }
    var currentURL: String? { lock.withLock { currentSnapshot.currentURL } }

    func attach(to window: HWND?) {
      guard let window else { return }
      let next = lock.withLock { () -> (any WindowsChatBrowserWorker)? in
        guard parentWindow == nil, !stopping else { return nil }
        parentWindow = window
        return enabled && closingWorkers.isEmpty ? createWorker(for: selectedSite) : nil
      }
      next?.start()
    }

    func selectSite(_ site: ChatBrowserSite) {
      let next = lock.withLock { () -> (any WindowsChatBrowserWorker)? in
        guard !stopping, selectedSite != site else { return nil }
        selectedSite = site
        preferences.selectedSite = site
        let next = enabled && closingWorkers.isEmpty ? createWorker(for: site) : nil
        applyWorkerLayout()
        return next
      }
      next?.start()
    }

    func setEnabled(_ enabled: Bool) {
      let change = lock.withLock {
        () -> (
          next: (any WindowsChatBrowserWorker)?,
          removed: [ChatBrowserSite: any WindowsChatBrowserWorker]
        ) in
        guard !stopping, self.enabled != enabled else { return (nil, [:]) }
        self.enabled = enabled
        if enabled {
          return (closingWorkers.isEmpty ? createWorker(for: selectedSite) : nil, [:])
        }
        let removed = workers
        workers.removeAll()
        for (site, worker) in removed {
          closingWorkers[site] = worker
        }
        return (nil, removed)
      }
      for (site, worker) in change.removed {
        worker.shutdown { [weak self] in self?.workerDidClose(for: site) }
      }
      change.next?.start()
    }

    private func workerDidClose(for site: ChatBrowserSite) {
      let next = lock.withLock { () -> (any WindowsChatBrowserWorker)? in
        guard closingWorkers.removeValue(forKey: site) != nil else { return nil }
        generations.removeValue(forKey: site)
        snapshots[site] = Snapshot(url: preferences.resumeURL(for: site))
        guard !stopping, enabled, closingWorkers.isEmpty else { return nil }
        return createWorker(for: selectedSite)
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
      let active = lock.withLock { () -> [any WindowsChatBrowserWorker] in
        stopping = true
        return Array(workers.values) + Array(closingWorkers.values)
      }
      return active.reduce(0) { count, worker in
        count + (worker.beginShutdown(notifying: window, message: message) ? 1 : 0)
      }
    }

    func shutdown() {
      let active = lock.withLock { () -> [any WindowsChatBrowserWorker] in
        stopping = true
        generations.removeAll()
        defer {
          workers.removeAll()
          closingWorkers.removeAll()
        }
        return Array(workers.values) + Array(closingWorkers.values)
      }
      for worker in active { worker.shutdown() }
    }

    private var currentSnapshot: Snapshot {
      snapshots[selectedSite] ?? Snapshot(url: preferences.resumeURL(for: selectedSite))
    }

    private func createWorker(for site: ChatBrowserSite) -> (any WindowsChatBrowserWorker)? {
      guard workers[site] == nil, let parentWindow else { return nil }
      let initialURL = preferences.resumeURL(for: site)
      snapshots[site] = Snapshot(url: initialURL)
      nextGeneration &+= 1
      let generation = nextGeneration
      generations[site] = generation
      let worker = workerFactory(
        parentWindow, .chatBrowser(site: site, initialURL: initialURL.absoluteString),
        { [weak self] state, detail in
          self?.store(state: state, errorDetail: detail, for: site, generation: generation)
        },
        { [weak self] canGoBack, canGoForward, currentURL in
          self?.storeNavigation(
            canGoBack: canGoBack, canGoForward: canGoForward,
            currentURL: currentURL, for: site, generation: generation
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

    private func store(
      state: State, errorDetail: String?, for site: ChatBrowserSite, generation: UInt64
    ) {
      lock.withLock {
        guard generations[site] == generation, var snapshot = snapshots[site] else { return }
        snapshot.state = state
        snapshot.errorDetail = errorDetail
        snapshots[site] = snapshot
      }
    }

    private func storeNavigation(
      canGoBack: Bool, canGoForward: Bool, currentURL: String?, for site: ChatBrowserSite,
      generation: UInt64
    ) {
      let safeURL = site.validatedURL(currentURL.flatMap(URL.init(string:)))
      lock.withLock {
        guard generations[site] == generation, var snapshot = snapshots[site] else { return }
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
