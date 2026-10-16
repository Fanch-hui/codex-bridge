#if os(Windows)
  import BridgeServiceAppCore
  import Foundation

  struct WindowsWebViewConfiguration: Sendable, Equatable {
    let purpose: Purpose
    let profileName: String
    let initialURL: String
    let disableDefaultContextMenu: Bool
    let disableStatusBar: Bool
    let disableDevTools: Bool
    let disableZoomControl: Bool
    let defaultBackgroundColor: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)?

    enum Purpose: Sendable, Equatable {
      case desktopUI
      case chatBrowser
    }

    static func desktopUI(initialURL: String) -> WindowsWebViewConfiguration {
      WindowsWebViewConfiguration(
        purpose: .desktopUI,
        profileName: "DesktopUI",
        initialURL: initialURL,
        disableDefaultContextMenu: true,
        disableStatusBar: true,
        disableDevTools: true,
        disableZoomControl: true,
        defaultBackgroundColor: WindowsSystemAppearance.canvasColor
      )
    }

    static func chatBrowser(
      site: ChatBrowserSite = .chatGPT,
      initialURL: String? = nil
    ) -> WindowsWebViewConfiguration {
      WindowsWebViewConfiguration(
        purpose: .chatBrowser,
        profileName: site == .chatGPT ? "WebView2" : "GeminiWebView2",
        initialURL: initialURL ?? site.homeURL.absoluteString,
        disableDefaultContextMenu: false,
        disableStatusBar: false,
        disableDevTools: false,
        disableZoomControl: false,
        defaultBackgroundColor: (r: 255, g: 255, b: 255, a: 255)
      )
    }

    var hasCustomSettings: Bool {
      disableDefaultContextMenu || disableStatusBar || disableDevTools || disableZoomControl
    }

    var defaultZoomFactor: Double? {
      purpose == .desktopUI ? 1.0 : nil
    }

    static func == (lhs: WindowsWebViewConfiguration, rhs: WindowsWebViewConfiguration) -> Bool {
      lhs.purpose == rhs.purpose && lhs.profileName == rhs.profileName
        && lhs.initialURL == rhs.initialURL
        && lhs.disableDefaultContextMenu == rhs.disableDefaultContextMenu
        && lhs.disableStatusBar == rhs.disableStatusBar
        && lhs.disableDevTools == rhs.disableDevTools
        && lhs.disableZoomControl == rhs.disableZoomControl
        && lhs.defaultBackgroundColor?.r == rhs.defaultBackgroundColor?.r
        && lhs.defaultBackgroundColor?.g == rhs.defaultBackgroundColor?.g
        && lhs.defaultBackgroundColor?.b == rhs.defaultBackgroundColor?.b
        && lhs.defaultBackgroundColor?.a == rhs.defaultBackgroundColor?.a
    }
  }
#endif
