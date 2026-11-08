#if os(Linux)
  import BridgeDesktopUI
  import BridgeServiceAppCore
  import CLinuxDesktop
  import Foundation

  enum LinuxDesktopHost {
    struct BrowserSnapshot: Equatable, Sendable {
      var site: ChatBrowserSite = .chatGPT
      var state = "loading"
      var url = "https://chatgpt.com/"
      var error: String?
      var canGoBack = false
      var canGoForward = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var commands: [MainWindowCommand] = []
    nonisolated(unsafe) private static var fileRequests: [String: @Sendable (String?) -> Void] = [:]
    @MainActor private(set) static var browser = BrowserSnapshot()
    @MainActor private static var browserRequestedEnabled = false
    @MainActor private static var browserReleasePending = false

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
      let started = page.absoluteString.withCString { pagePointer in
        data.path.withCString { bridge_linux_start(pagePointer, $0) != 0 }
      }
      if started {
        selectBrowserSite(ChatBrowserPreferences(defaults: .standard).selectedSite)
      }
      return started
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
        case "browser-closed":
          browserDidClose()
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
      let parts = event.split(separator: "\n", maxSplits: 5, omittingEmptySubsequences: false)
      guard parts.count == 6, let site = ChatBrowserSite(rawValue: String(parts[0])) else { return }
      let preferences = ChatBrowserPreferences(defaults: .standard)
      if let url = URL(string: String(parts[4])) { preferences.remember(url, for: site) }
      guard site == preferences.selectedSite else { return }
      browser = BrowserSnapshot(
        site: site, state: String(parts[1]), url: String(parts[4]),
        error: parts[5].isEmpty ? nil : String(parts[5]),
        canGoBack: parts[2] == "1", canGoForward: parts[3] == "1")
    }

    private static func receiveFile(_ event: String) {
      let parts = event.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { return }
      let callback = lock.withLock { fileRequests.removeValue(forKey: String(parts[0])) }
      callback?(parts[1].isEmpty ? nil : String(parts[1]))
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

    @MainActor
    static func setBrowserEnabled(_ enabled: Bool) {
      browserRequestedEnabled = enabled
      if enabled {
        guard !browserReleasePending else { return }
        reopenBrowser()
      } else {
        guard !browserReleasePending else { return }
        browserReleasePending = true
        bridge_linux_browser_enabled(0)
      }
    }

    @MainActor
    private static func browserDidClose() {
      browserReleasePending = false
      let preferences = ChatBrowserPreferences(defaults: .standard)
      browser = BrowserSnapshot(
        site: preferences.selectedSite,
        url: preferences.resumeURL(for: preferences.selectedSite).absoluteString)
      if browserRequestedEnabled { reopenBrowser() }
    }

    @MainActor
    private static func reopenBrowser() {
      selectBrowserSite(ChatBrowserPreferences(defaults: .standard).selectedSite)
      bridge_linux_browser_enabled(1)
    }

    static func setBrowserPresentationVisible(_ visible: Bool) {
      bridge_linux_browser_presentation_visible(visible ? 1 : 0)
    }

    static func browserAction(_ action: Int32) { bridge_linux_browser_action(action) }

    static func selectBrowserSite(_ site: ChatBrowserSite) {
      let preferences = ChatBrowserPreferences(defaults: .standard)
      preferences.selectedSite = site
      site.rawValue.withCString { identifier in
        preferences.resumeURL(for: site).absoluteString.withCString {
          bridge_linux_browser_select(identifier, $0)
        }
      }
    }

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
      chooseFileIncludingCancellation(title: title, directory: directory) { path in
        if let path { completion(path) }
      }
    }

    static func chooseFileIncludingCancellation(
      title: String, directory: Bool,
      completion: @escaping @Sendable (String?) -> Void
    ) {
      let id = UUID().uuidString
      lock.withLock { fileRequests[id] = completion }
      id.withCString { identifier in
        title.withCString { bridge_linux_choose_file(identifier, $0, directory ? 1 : 0) }
      }
    }

    static func chooseSaveFile(completion: @escaping @Sendable (String?) -> Void) {
      let id = UUID().uuidString
      lock.withLock { fileRequests[id] = completion }
      id.withCString { identifier in
        "导出会话内容".withCString { title in
          "会话内容.txt".withCString { bridge_linux_save_file(identifier, title, $0) }
        }
      }
    }
  }
#endif
