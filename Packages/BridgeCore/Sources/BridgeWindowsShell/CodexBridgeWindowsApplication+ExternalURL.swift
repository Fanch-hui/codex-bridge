#if os(Windows)
  import BridgeDesktopUI
  import Foundation
  import WinSDK

  extension CodexBridgeWindowsApplication {
    nonisolated static func openExternalURL(_ value: String) {
      guard let address = BridgeDesktopExternalURL.resolve(value)?.absoluteString else { return }
      "open".withCString(encodedAs: UTF16.self) { operation in
        address.withCString(encodedAs: UTF16.self) { url in
          _ = ShellExecuteW(
            WindowsMainWindow.currentWindow(), operation, url, nil, nil, SW_SHOWNORMAL)
        }
      }
    }
  }
#endif
