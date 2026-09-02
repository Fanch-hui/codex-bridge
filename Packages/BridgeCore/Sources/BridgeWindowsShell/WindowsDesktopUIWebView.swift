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
    private var isPageReady = false

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

    func attach(to window: HWND?) {
      guard let window, let url = BridgeDesktopUI.indexURL() else {
        store(state: .failed, errorDetail: "缺少随应用安装的 Desktop UI 资源。")
        return
      }
      let next = WindowsWebViewThread(
        parentWindow: window,
        initialURL: url.absoluteString,
        profileName: "DesktopUI",
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

    func setState(_ state: BridgeDesktopUIState) {
      let shouldSend = lock.withLock { () -> Bool in
        guard latestState != state else { return false }
        latestState = state
        return isPageReady
      }
      if shouldSend { sendLatestState() }
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

    private func sendLatestState() {
      let value = lock.withLock { latestState }
      guard
        let value,
        let data = try? JSONEncoder().encode(value),
        let message = String(data: data, encoding: .utf8)
      else { return }
      lock.withLock { worker }?.postWebMessageAsJSON(message)
    }

    private func receive(_ message: String) {
      guard
        let data = message.data(using: .utf8),
        let envelope = try? JSONDecoder().decode(BridgeDesktopCommandEnvelope.self, from: data),
        envelope.version == BridgeDesktopCommandEnvelope.currentVersion,
        !envelope.requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        envelope.requestID.count <= 128
      else { return }
      if envelope.command == .ready {
        lock.withLock { isPageReady = true }
        sendLatestState()
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
