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

  var isChatBrowserActive: Bool {
    isChatBrowserEnabled && isLightweightMode == false
  }

  var chatBrowserResumeURL: URL { chatBrowserSessions.resumeURL }

  var chatBrowserLoadError: String? {
    get { chatBrowserViewport.loadError }
    set {
      guard chatBrowserViewport.loadError != newValue else { return }
      objectWillChange.send()
      chatBrowserViewport.loadError = newValue
    }
  }

  func setChatBrowserLoadError(
    _ message: String?,
    for site: ChatBrowserSite,
    generation: UInt64? = nil
  ) {
    guard site == chatBrowserSite else { return }
    if let generation, chatBrowserSessions.generation != generation { return }
    chatBrowserLoadError = message
  }

  func notifyChatBrowserNavigationChanged(
    for site: ChatBrowserSite,
    generation: UInt64? = nil
  ) {
    guard site == chatBrowserSite else { return }
    if let generation, chatBrowserSessions.generation != generation { return }
    objectWillChange.send()
    chatBrowserViewport.loadError = nil
  }

  func chatWebViewBinding(for site: ChatBrowserSite) -> Binding<WKWebView?> {
    let generation = chatBrowserSessions.generation
    return Binding(
      get: {
        guard self.isChatBrowserActive, self.chatBrowserSessions.generation == generation else {
          return nil
        }
        return self.chatBrowserSessions.webView(for: site)
      },
      set: { webView in
        guard self.isChatBrowserActive, self.chatBrowserSessions.generation == generation else {
          if let webView, self.chatBrowserSessions.webView(for: site) !== webView {
            ChatBrowserSessions.detach(webView)
          }
          return
        }
        self.setChatWebView(webView, for: site)
      }
    )
  }

  private func setChatWebView(_ webView: WKWebView?, for site: ChatBrowserSite) {
    guard isChatBrowserActive else {
      if let webView { ChatBrowserSessions.detach(webView) }
      return
    }
    guard chatBrowserSessions.webView(for: site) !== webView else { return }
    objectWillChange.send()
    chatBrowserSessions.setWebView(webView, for: site)
    if webView != nil { updateChatBrowserVisibility() }
  }

  func selectChatBrowserSite(_ site: ChatBrowserSite) {
    guard site != chatBrowserSite else { return }
    objectWillChange.send()
    chatBrowserViewport.loadError = nil
    chatBrowserSessions.select(site)
    updateChatBrowserVisibility()
  }

  func updateChatBrowserVisibility() {
    if selection != .workbench {
      chatBrowserViewport.update(nil)
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
    chatBrowserViewport.loadError = nil
    chatBrowserReloadRequest &+= 1
  }

  func releaseChatWebView() {
    objectWillChange.send()
    chatBrowserViewport.loadError = nil
    chatBrowserSessions.release()
  }
}
