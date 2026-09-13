import AppKit
import BridgeDesktopUI
import Foundation
import SwiftUI
import WebKit

struct BridgeDesktopWebView: NSViewRepresentable {
  @ObservedObject var model: BridgeServiceAppModel

  func makeCoordinator() -> Coordinator {
    Coordinator(model: model)
  }

  func makeNSView(context: Context) -> WKWebView {
    let userContentController = WKUserContentController()
    userContentController.add(context.coordinator, name: "bridgeDesktopUI")

    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.userContentController = userContentController
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.setValue(false, forKey: "drawsBackground")

    guard let indexURL = BridgeDesktopUI.indexURL() else {
      context.coordinator.failLoading()
      return webView
    }
    webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
    context.coordinator.update(
      state: BridgeDesktopUIStateBuilder.build(from: model),
      webView: webView
    )
    return webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {
    let state = BridgeDesktopUIStateBuilder.build(from: model)
    context.coordinator.update(
      state: state,
      webView: nsView
    )
  }

  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    weak var model: BridgeServiceAppModel?
    private var latestState: BridgeDesktopUIState?
    private var didFinishLoading = false

    init(model: BridgeServiceAppModel) {
      self.model = model
    }

    func update(state: BridgeDesktopUIState, webView: WKWebView) {
      guard latestState != state else { return }
      latestState = state
      sendLatestState(to: webView)
    }

    func failLoading() {
      didFinishLoading = true
    }

    func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
      guard let envelope = decode(message.body) else { return }
      handle(envelope)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      didFinishLoading = true
      sendLatestState(to: webView)
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
      navigationAction.request.url?.isFileURL == true ? .allow : .cancel
    }

    deinit {
      model = nil
    }

    private func sendLatestState(to webView: WKWebView) {
      guard didFinishLoading, let latestState,
        let data = try? JSONEncoder().encode(latestState),
        let json = String(data: data, encoding: .utf8),
        let literalData = try? JSONEncoder().encode(json),
        let literal = String(data: literalData, encoding: .utf8)
      else { return }
      let script =
        "window.CodexBridgeDesktopUI && window.CodexBridgeDesktopUI.setState(JSON.parse(\(literal)))"
      webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func decode(_ body: Any) -> BridgeDesktopCommandEnvelope? {
      let data: Data?
      if let string = body as? String {
        data = string.data(using: .utf8)
      } else if JSONSerialization.isValidJSONObject(body) {
        data = try? JSONSerialization.data(withJSONObject: body)
      } else {
        data = nil
      }
      guard let data,
        let envelope = try? JSONDecoder().decode(BridgeDesktopCommandEnvelope.self, from: data),
        envelope.version == BridgeDesktopCommandEnvelope.currentVersion,
        !envelope.requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        envelope.requestID.count <= 128
      else { return nil }
      return envelope
    }

    private func handle(_ envelope: BridgeDesktopCommandEnvelope) {
      guard let model else { return }
      Task { @MainActor [weak model] in
        guard let model else { return }
        BridgeDesktopCommandRouter.handle(envelope, model: model)
      }
    }

  }
}
