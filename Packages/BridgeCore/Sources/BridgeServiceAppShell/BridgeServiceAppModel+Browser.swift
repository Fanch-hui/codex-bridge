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
    let generation = chatBrowserSessions.generation
    return Binding(
      get: {
        guard self.isChatBrowserEnabled, self.chatBrowserSessions.generation == generation else {
          return nil
        }
        return self.chatBrowserSessions.webView(for: site)
      },
      set: { webView in
        guard self.isChatBrowserEnabled, self.chatBrowserSessions.generation == generation else {
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
    guard isChatBrowserEnabled else {
      if let webView { ChatBrowserSessions.detach(webView) }
      return
    }
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
    chatBrowserReloadRequest &+= 1
  }

  func releaseChatWebView() {
    objectWillChange.send()
    chatBrowserSessions.release()
  }
}
