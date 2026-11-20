import BridgeDesktopUI
import BridgeServiceAppCore
import Combine
import SwiftUI

/// Geometry of the native chat browser. It is kept out of `BridgeServiceAppModel` so that a
/// viewport drag only re-renders the overlay instead of every view observing the model.
@MainActor
final class ChatBrowserViewportState: ObservableObject {
  @Published private(set) var viewport: BridgeDesktopBrowserViewport?
  var loadError: String?

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
      viewport.width > 0,
      viewport.height > 0,
      model.navigation == .workbench,
      model.isChatBrowserActive
    {
      let site = model.chatBrowserSite
      let generation = model.chatBrowserSessions.generation
      ChatGPTWebView(
        site: site,
        initialURL: model.chatBrowserResumeURL,
        reloadRequest: model.chatBrowserReloadRequest,
        viewportSize: CGSize(width: viewport.width, height: viewport.height),
        webViewReference: model.chatWebViewBinding(for: site),
        onLoadError: { [weak model] message in
          model?.setChatBrowserLoadError(message, for: site, generation: generation)
        },
        onNavigationChange: { [weak model] in
          model?.notifyChatBrowserNavigationChanged(for: site, generation: generation)
        }
      )
      .id("\(site.rawValue):\(generation)")
      .frame(width: viewport.width, height: viewport.height)
      .offset(x: viewport.x, y: viewport.y)
    }
  }
}
