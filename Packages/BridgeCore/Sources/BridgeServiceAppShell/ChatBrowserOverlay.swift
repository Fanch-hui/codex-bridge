import BridgeDesktopUI
import BridgeServiceAppCore
import Combine
import SwiftUI

/// Geometry of the native chat browser. It is kept out of `BridgeServiceAppModel` so that a
/// viewport drag only re-renders the overlay instead of every view observing the model.
@MainActor
final class ChatBrowserViewportState: ObservableObject {
  @Published private(set) var viewport: BridgeDesktopBrowserViewport?

  func update(_ viewport: BridgeDesktopBrowserViewport?) {
    guard self.viewport != viewport else { return }
    self.viewport = viewport
  }
}

struct ChatBrowserOverlay: View {
  @ObservedObject var model: BridgeServiceAppModel
  @ObservedObject var viewportState: ChatBrowserViewportState

  var body: some View {
    if let viewport = viewportState.viewport,
      viewport.visible,
      model.navigation == .workbench,
      model.isChatBrowserEnabled
    {
      ChatGPTWebView(
        site: model.chatBrowserSite,
        initialURL: model.chatBrowserResumeURL,
        reloadRequest: model.chatBrowserReloadRequest,
        webViewReference: model.chatWebViewBinding(for: model.chatBrowserSite)
      )
      .id("\(model.chatBrowserSite.rawValue):\(model.chatBrowserSessions.generation)")
      .frame(width: viewport.width, height: viewport.height)
      .offset(x: viewport.x, y: viewport.y)
    }
  }
}
