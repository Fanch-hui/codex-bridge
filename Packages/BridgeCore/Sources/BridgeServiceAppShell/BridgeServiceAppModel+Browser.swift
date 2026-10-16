import BridgeServiceAppCore
import Foundation
import SwiftUI
import WebKit

extension BridgeServiceAppModel {
  public var chatWebView: WKWebView? {
    get { chatBrowserSessions.selectedWebView }
    set {
      setChatWebView(newValue, for: chatBrowserSite)
    }
  }

  public var chatBrowserSite: ChatBrowserSite { chatBrowserSessions.selectedSite }

  var chatBrowserResumeURL: URL { chatBrowserSessions.resumeURL }

  func chatWebViewBinding(for site: ChatBrowserSite) -> Binding<WKWebView?> {
    Binding(
      get: { self.chatBrowserSessions.webView(for: site) },
      set: { webView in
        guard self.isChatBrowserEnabled else { return }
        self.setChatWebView(webView, for: site)
      }
    )
  }

  private func setChatWebView(_ webView: WKWebView?, for site: ChatBrowserSite) {
    objectWillChange.send()
    chatBrowserSessions.setWebView(webView, for: site)
    if webView != nil { updateChatBrowserVisibility() }
  }

  func selectChatBrowserSite(_ site: ChatBrowserSite) {
    guard site != chatBrowserSite else { return }
    objectWillChange.send()
    chatBrowserSessions.select(site)
    updateChatBrowserVisibility()
  }

  func updateChatBrowserVisibility() {
    if selection != .workbench, chatBrowserViewport != nil {
      chatBrowserViewport = nil
    }
    cancelChatBrowserSleep()
    guard isChatBrowserEnabled, selection != .workbench, chatBrowserSessions.hasWebViews else {
      return
    }
    let delay = chatBrowserSleepDelay
    chatWebViewSleepTask = Task { [weak self] in
      do {
        try await Task.sleep(for: delay)
      } catch {
        return
      }
      guard let self,
        self.selection != .workbench,
        self.isChatBrowserEnabled
      else { return }
      self.chatWebViewSleepTask = nil
      self.releaseChatWebView()
    }
  }

  func cancelChatBrowserSleep() {
    chatWebViewSleepTask?.cancel()
    chatWebViewSleepTask = nil
  }

  func reloadChatBrowser() {
    guard isChatBrowserEnabled else { return }
    cancelChatBrowserSleep()
    chatBrowserReloadRequest &+= 1
  }

  func releaseChatWebView() {
    objectWillChange.send()
    chatBrowserSessions.release()
  }
}
