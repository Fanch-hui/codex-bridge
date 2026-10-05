#if os(Windows) || os(Linux)
  import BridgeDesktopUI
  import BridgeServiceAppCore
  import Foundation

  enum DesktopPlatformHost {
    static var platform: BridgeDesktopPlatform {
      #if os(Windows)
        .windows
      #else
        .linux
      #endif
    }

    static var platformName: String { platform == .windows ? "Windows" : "Ubuntu" }

    static func enqueue(_ action: @escaping @Sendable () -> Void) {
      #if os(Windows)
        WindowsUIThread.shared.enqueue(action)
      #else
        action()
      #endif
    }

    static func enqueueCommand(_ command: MainWindowCommand) {
      #if os(Windows)
        WindowsMainWindow.enqueue(command)
      #else
        LinuxDesktopHost.enqueueCommand(command)
      #endif
    }

    static func selectPage(_ page: WindowsMainPage) {
      #if os(Windows)
        WindowsMainWindow.selectPage(page)
      #endif
    }

    static func applyBrowserViewport(_ viewport: BridgeDesktopBrowserViewport) {
      #if os(Windows)
        WindowsMainWindow.applyBrowserViewport(viewport)
      #else
        LinuxDesktopHost.applyBrowserViewport(viewport)
      #endif
    }

    static func browserBack() {
      #if os(Windows)
        WindowsMainWindow.chat?.goBack()
      #else
        LinuxDesktopHost.browserAction(0)
      #endif
    }

    static func browserForward() {
      #if os(Windows)
        WindowsMainWindow.chat?.goForward()
      #else
        LinuxDesktopHost.browserAction(1)
      #endif
    }

    static func browserReload() {
      #if os(Windows)
        WindowsMainWindow.chat?.reload()
      #else
        LinuxDesktopHost.browserAction(2)
      #endif
    }

    @discardableResult
    static func copy(_ text: String) -> Bool {
      #if os(Windows)
        WindowsClipboard.write(text, owner: WindowsMainWindow.currentWindow())
      #else
        LinuxDesktopHost.copy(text)
      #endif
    }

    static func openExternalURL(_ address: String) {
      #if os(Windows)
        WindowsExternalURLHost.open(address)
      #else
        LinuxDesktopHost.openExternalURL(address)
      #endif
    }

    static func chooseProjectDirectory(
      completion: @escaping @Sendable (String, String) -> Void
    ) {
      #if os(Windows)
        WindowsDesktopUIHostActions.chooseProjectDirectory(completion: completion)
      #else
        LinuxDesktopHost.chooseFile(title: "选择项目目录", directory: true) { path in
          completion(URL(fileURLWithPath: path).lastPathComponent, path)
        }
      #endif
    }

    static func chooseExecutableFile(
      title: String = "选择 Agent 可执行文件",
      completion: @escaping @Sendable (String) -> Void
    ) {
      #if os(Windows)
        WindowsDesktopUIHostActions.chooseExecutableFile(title: title, completion: completion)
      #else
        LinuxDesktopHost.chooseFile(title: title, directory: false, completion: completion)
      #endif
    }

    static func chooseConfigFile(
      title: String = "选择 Agent 配置文件",
      completion: @escaping @Sendable (String) -> Void
    ) {
      #if os(Windows)
        WindowsDesktopUIHostActions.chooseConfigFile(title: title, completion: completion)
      #else
        LinuxDesktopHost.chooseFile(title: title, directory: false, completion: completion)
      #endif
    }
  }

  enum DesktopServiceLauncher {
    static func ensureServiceRunning() -> ServiceLaunchOutcome {
      #if os(Windows)
        WindowsServiceLauncher.ensureServiceRunning()
      #else
        // The Linux launcher cannot observe an exited child today, so a
        // failed readiness check is reported as a plain launch failure.
        LinuxDesktopService.ensureRunning() ? .ready : .launchFailed(systemError: nil)
      #endif
    }
  }

  enum DesktopServiceRegistration {
    static func isRegistered() -> Bool {
      #if os(Windows)
        WindowsServiceRegistration.isRegistered()
      #else
        LinuxDesktopService.isRegistered()
      #endif
    }

    static func register() throws {
      #if os(Windows)
        try WindowsServiceRegistration.register()
      #else
        try LinuxDesktopService.register()
      #endif
    }

    static func unregister() throws {
      #if os(Windows)
        try WindowsServiceRegistration.unregister()
      #else
        try LinuxDesktopService.unregister()
      #endif
    }
  }
#endif

#if os(Windows)
  import WinSDK

  enum WindowsExternalURLHost {
    static func open(_ address: String) {
      "open".withCString(encodedAs: UTF16.self) { operation in
        address.withCString(encodedAs: UTF16.self) { url in
          _ = ShellExecuteW(
            WindowsMainWindow.currentWindow(), operation, url, nil, nil, SW_SHOWNORMAL)
        }
      }
    }
  }

  public typealias CodexBridgeWindowsApplication = CodexBridgeDesktopApplication
#endif
