import AppKit
import BridgeServiceAppCore
import Foundation
import WebKit

final class ChatBrowserWKWebView: WKWebView {
  var onDidMoveToWindow: (@MainActor (WKWebView) -> Void)?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    onDidMoveToWindow?(self)
  }
}

extension ChatGPTWebView {
  static let geminiWebsiteDataStoreIdentifier = UUID(
    uuid: (
      0x63, 0x6F, 0x64, 0x65, 0x78, 0x62, 0x72, 0x69,
      0x64, 0x67, 0x65, 0x67, 0x65, 0x6D, 0x69, 0x31
    ))

  static func safeSize(for size: CGSize) -> CGSize {
    let width = size.width.isFinite ? max(1, size.width) : 1
    let height = size.height.isFinite ? max(1, size.height) : 1
    return CGSize(width: width, height: height)
  }

  static func safeFrame(for frame: NSRect) -> NSRect {
    NSRect(origin: .zero, size: safeSize(for: frame.size))
  }

  static func setDrawsBackground(_ drawsBackground: Bool, on webView: WKWebView) {
    webView.setValue(drawsBackground, forKey: "drawsBackground")
  }

  static func makeWebView(
    for site: ChatBrowserSite,
    initialFrame: NSRect = .zero
  ) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore =
      site == .chatGPT
      ? WKWebsiteDataStore.default()
      : WKWebsiteDataStore(forIdentifier: geminiWebsiteDataStoreIdentifier)
    configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    let webView = ChatBrowserWKWebView(
      frame: safeFrame(for: initialFrame),
      configuration: configuration
    )
    webView.autoresizingMask = [.width, .height]
    setDrawsBackground(false, on: webView)
    if site == .chatGPT {
      webView.customUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
    }
    return webView
  }
}
