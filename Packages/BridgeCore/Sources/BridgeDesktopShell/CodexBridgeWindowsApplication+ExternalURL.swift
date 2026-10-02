#if os(Windows) || os(Linux)
  import BridgeDesktopUI
  import Foundation

  extension CodexBridgeDesktopApplication {
    nonisolated static func openExternalURL(_ value: String) {
      guard let address = BridgeDesktopExternalURL.resolve(value)?.absoluteString else { return }
      DesktopPlatformHost.openExternalURL(address)
    }
  }
#endif
