import BridgeServiceAppCore
import Foundation
import WebKit

extension ChatGPTWebView {
  static let geminiWebsiteDataStoreIdentifier = UUID(
    uuid: (
      0x63, 0x6F, 0x64, 0x65, 0x78, 0x62, 0x72, 0x69,
      0x64, 0x67, 0x65, 0x67, 0x65, 0x6D, 0x69, 0x31
    ))

  static func makeWebView(for site: ChatBrowserSite) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore =
      site == .chatGPT
      ? WKWebsiteDataStore.default()
      : WKWebsiteDataStore(forIdentifier: geminiWebsiteDataStoreIdentifier)
    configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    let webView = WKWebView(frame: .zero, configuration: configuration)
    if site == .chatGPT {
      webView.customUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
    }
    return webView
  }
}
