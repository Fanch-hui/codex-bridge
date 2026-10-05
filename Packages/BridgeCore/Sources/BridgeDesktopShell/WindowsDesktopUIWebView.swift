#if os(Windows)
  import BridgeDesktopUI
  import Foundation
  import WinSDK

  final class WindowsDesktopUIWebView: @unchecked Sendable {
    typealias State = WindowsChatWebView.State
    typealias CommandHandler = @Sendable (BridgeDesktopCommandEnvelope) -> Void

    private let lock = NSLock()
    private let commandHandler: CommandHandler
    private var snapshot = Snapshot(state: .loading, errorDetail: nil)
    private var worker: WindowsWebViewThread?
    private var latestState: BridgeDesktopUIState?
    private var latestStateRevision: UInt64?
    private var patchBuilder = BridgeDesktopUIStatePatchBuilder()
    private var isPageReady = false
    private var readyDeadline: UInt64 = 0

    /// Loading the local page needs the WebView2 runtime, the environment, the
    /// controller and the JS bootstrap; a stall past this grace is a broken install.
    private static let readyGraceNanoseconds: UInt64 = 20_000_000_000

    init(commandHandler: @escaping CommandHandler) {
      self.commandHandler = commandHandler
    }

    var state: State {
      lock.withLock { snapshot.state }
    }

    var errorDetail: String? {
      lock.withLock { snapshot.errorDetail }
    }

    var isReady: Bool {
      lock.withLock { snapshot.state == .active && isPageReady }
    }

    /// True while the page has not announced itself and the grace period is over,
    /// which is how a stalled or half-installed bundle becomes visible instead of blank.
    var loadStalled: Bool {
      lock.withLock {
        readyDeadline != 0 && !isPageReady && DispatchTime.now().uptimeNanoseconds > readyDeadline
      }
    }

    func attach(to window: HWND?) {
      guard let window, let url = BridgeDesktopUI.indexURL() else {
        store(state: .failed, errorDetail: "缺少随应用安装的 Desktop UI 资源。")
        return
      }
      let next = WindowsWebViewThread(
        parentWindow: window,
        configuration: .desktopUI(initialURL: Self.windowsURL(from: url)),
        updateState: { [weak self] state, detail in
          self?.store(state: state, errorDetail: detail)
        },
        onWebMessage: { [weak self] message in
          self?.receive(message)
        }
      )
      guard
        lock.withLock({
          guard worker == nil else { return false }
          worker = next
          readyDeadline = DispatchTime.now().uptimeNanoseconds + Self.readyGraceNanoseconds
          return true
        })
      else { return }
      next.start()
    }

    private static func windowsURL(from url: URL) -> String {
      guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return url.absoluteString
      }
      components.queryItems = [URLQueryItem(name: "platform", value: "windows")]
      return components.url?.absoluteString ?? url.absoluteString
    }

    func resize(to bounds: RECT) {
      lock.withLock { worker }?.resize(to: bounds)
    }

    func setVisible(_ visible: Bool) {
      lock.withLock { worker }?.setVisible(visible)
    }

    func applyLayout(to bounds: RECT, visible: Bool) {
      lock.withLock { worker }?.applyLayout(to: bounds, visible: visible)
    }

    /// Builds and encodes the patch for `state` off the UI thread. The render
    /// pipeline is serial, and the lock keeps the builder consistent with the
    /// webview-thread resync path.
    func preparedPatch(for state: BridgeDesktopUIState, revision: UInt64) -> PreparedPatch? {
      lock.withLock { () -> PreparedPatch? in
        guard latestStateRevision != revision else { return nil }
        let patch = patchBuilder.makePatch(state: state, nextRevision: revision)
        latestState = state
        latestStateRevision = revision
        guard isPageReady else { return nil }
        guard let data = try? JSONEncoder().encode(patch),
          let message = String(data: data, encoding: .utf8)
        else { return nil }
        return PreparedPatch(message: message, replacesPendingMessages: patch.isFull)
      }
    }

    /// Posts a patch that was encoded off the UI thread; O(1) on the pump.
    func post(_ prepared: PreparedPatch) {
      lock.withLock { worker }?.postWebMessageAsJSON(
        prepared.message, replacesPendingMessages: prepared.replacesPendingMessages)
    }

    struct PreparedPatch: Sendable {
      let message: String
      let replacesPendingMessages: Bool
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

    private func sendFullSnapshot() {
      let prepared = lock.withLock { () -> PreparedPatch? in
        guard let state = latestState, let revision = latestStateRevision else { return nil }
        guard isPageReady else { return nil }
        let patch = patchBuilder.fullSnapshot(state: state, revision: revision)
        guard let data = try? JSONEncoder().encode(patch),
          let message = String(data: data, encoding: .utf8)
        else { return nil }
        return PreparedPatch(message: message, replacesPendingMessages: true)
      }
      if let prepared { post(prepared) }
    }

    private func receive(_ message: String) {
      guard
        let data = message.data(using: .utf8),
        let envelope = try? JSONDecoder().decode(BridgeDesktopCommandEnvelope.self, from: data),
        envelope.version == BridgeDesktopCommandEnvelope.currentVersion,
        !envelope.requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        envelope.requestID.count <= 128
      else { return }
      if envelope.command == .ready || envelope.command == .requestStateResync {
        lock.withLock { isPageReady = true }
        sendFullSnapshot()
        return
      }
      commandHandler(envelope)
    }

    private func store(state: State, errorDetail: String?) {
      lock.withLock {
        snapshot = Snapshot(state: state, errorDetail: errorDetail)
        if state != .active { isPageReady = false }
      }
    }

    private struct Snapshot {
      let state: State
      let errorDetail: String?
    }
  }
#endif
