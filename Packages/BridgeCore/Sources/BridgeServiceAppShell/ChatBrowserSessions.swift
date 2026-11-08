import BridgeServiceAppCore
import Foundation
import WebKit

@MainActor
final class ChatBrowserSessions {
  private let preferences: ChatBrowserPreferences
  private var webViews: [ChatBrowserSite: WKWebView] = [:]
  private(set) var generation: UInt64 = 0

  init(defaults: UserDefaults) {
    preferences = ChatBrowserPreferences(defaults: defaults)
  }

  var selectedSite: ChatBrowserSite { preferences.selectedSite }
  var hasWebViews: Bool { !webViews.isEmpty }
  var resumeURL: URL { preferences.resumeURL(for: selectedSite) }

  var selectedWebView: WKWebView? {
    get { webViews[selectedSite] }
    set { webViews[selectedSite] = newValue }
  }

  func webView(for site: ChatBrowserSite) -> WKWebView? { webViews[site] }

  func setWebView(_ webView: WKWebView?, for site: ChatBrowserSite) {
    webViews[site] = webView
  }

  func select(_ site: ChatBrowserSite) {
    rememberCurrentURLs()
    preferences.selectedSite = site
  }

  func release() {
    rememberCurrentURLs()
    generation &+= 1
    for webView in webViews.values {
      Self.detach(webView)
    }
    webViews.removeAll()
  }

  static func detach(_ webView: WKWebView) {
    webView.stopLoading()
    webView.navigationDelegate = nil
    webView.uiDelegate = nil
  }

  private func rememberCurrentURLs() {
    for (site, webView) in webViews {
      if let url = webView.url { preferences.remember(url, for: site) }
    }
  }
}
