#if os(Linux)
  import BridgeDesktopUI
  import CLinuxDesktop
  import Foundation

  enum LinuxDesktopHost {
    struct BrowserSnapshot: Equatable, Sendable {
      var state = "loading"
      var url = "https://chatgpt.com/"
      var error: String?
      var canGoBack = false
      var canGoForward = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var commands: [MainWindowCommand] = []
    nonisolated(unsafe) private static var fileRequests: [String: @Sendable (String) -> Void] = [:]
    @MainActor private(set) static var browser = BrowserSnapshot()

    static func start() -> Bool {
      guard let resource = BridgeDesktopUI.indexURL(),
        var components = URLComponents(url: resource, resolvingAgainstBaseURL: false)
      else { return false }
      components.queryItems = [URLQueryItem(name: "platform", value: "linux")]
      guard let page = components.url else { return false }
      let environment = ProcessInfo.processInfo.environment
      let root =
        environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        .path
      let data = URL(fileURLWithPath: root).appendingPathComponent("CodexBridge/WebView")
      do {
        try FileManager.default.createDirectory(
          at: data, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
      } catch { return false }
      return page.absoluteString.withCString { pagePointer in
        data.path.withCString { bridge_linux_start(pagePointer, $0) != 0 }
      }
    }

    static var isRunning: Bool { bridge_linux_running() != 0 }

    static func enqueueCommand(_ command: MainWindowCommand) {
      lock.withLock { commands.append(command) }
    }

    static func takeCommands() -> [MainWindowCommand] {
      lock.withLock {
        defer { commands.removeAll(keepingCapacity: true) }
        return commands
      }
    }

    @MainActor
    static func receiveEvents() -> Bool {
      var needsFullState = false
      while let raw = bridge_linux_next_event() {
        let event = String(cString: raw)
        bridge_linux_free(raw)
        let parts = event.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        switch parts[0] {
        case "command":
          guard let data = String(parts[1]).data(using: .utf8),
            let envelope = try? JSONDecoder().decode(BridgeDesktopCommandEnvelope.self, from: data),
            envelope.version == BridgeDesktopCommandEnvelope.currentVersion,
            !envelope.requestID.isEmpty, envelope.requestID.utf8.count <= 128
          else { continue }
          if envelope.command == .ready || envelope.command == .requestStateResync {
            needsFullState = true
          } else if let command = WindowsDesktopUICommandRouter.command(for: envelope) {
            enqueueCommand(command)
          }
        case "browser":
          receiveBrowser(String(parts[1]))
        case "file":
          receiveFile(String(parts[1]))
        default:
          break
        }
      }
      return needsFullState
    }

    @MainActor
    private static func receiveBrowser(_ event: String) {
      let parts = event.split(separator: "\n", maxSplits: 4, omittingEmptySubsequences: false)
      guard parts.count == 5 else { return }
      browser = BrowserSnapshot(
        state: String(parts[0]), url: String(parts[3]),
        error: parts[4].isEmpty ? nil : String(parts[4]),
        canGoBack: parts[1] == "1", canGoForward: parts[2] == "1")
    }

    private static func receiveFile(_ event: String) {
      let parts = event.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { return }
      let callback = lock.withLock { fileRequests.removeValue(forKey: String(parts[0])) }
      if !parts[1].isEmpty { callback?(String(parts[1])) }
    }

    static func send(_ patch: BridgeDesktopUIStatePatch) {
      guard let data = try? JSONEncoder().encode(patch),
        let json = String(data: data, encoding: .utf8)
      else { return }
      let script =
        "window.CodexBridgeDesktopUI && window.CodexBridgeDesktopUI.applyStatePatch(\(json));"
      script.withCString { bridge_linux_script($0) }
    }

    static func applyBrowserViewport(_ viewport: BridgeDesktopBrowserViewport) {
      guard
        [viewport.x, viewport.y, viewport.width, viewport.height].allSatisfy({
          $0.isFinite && abs($0) <= 65_536
        })
      else { return }
      bridge_linux_browser_viewport(
        viewport.x, viewport.y, viewport.width, viewport.height, viewport.visible ? 1 : 0)
    }

    static func setBrowserEnabled(_ enabled: Bool) {
      bridge_linux_browser_enabled(enabled ? 1 : 0)
    }

    static func browserAction(_ action: Int32) { bridge_linux_browser_action(action) }

    static func copy(_ text: String) -> Bool {
      text.withCString { bridge_linux_copy($0) }
      return true
    }

    static func openExternalURL(_ address: String) {
      guard let url = BridgeDesktopExternalURL.resolve(address) else { return }
      url.absoluteString.withCString { bridge_linux_open_uri($0) }
    }

    static func chooseFile(
      title: String, directory: Bool,
      completion: @escaping @Sendable (String) -> Void
    ) {
      let id = UUID().uuidString
      lock.withLock { fileRequests[id] = completion }
      id.withCString { identifier in
        title.withCString { bridge_linux_choose_file(identifier, $0, directory ? 1 : 0) }
      }
    }
  }
#endif
