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
    webView.uiDelegate = context.coordinator
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
    private var latestPatch: BridgeDesktopUIStatePatch?
    private var latestRevision: UInt64 = 0
    private var patchBuilder = BridgeDesktopUIStatePatchBuilder()
    private var didFinishLoading = false
    private let conversationObservation = DesktopConversationObservation()

    init(model: BridgeServiceAppModel) {
      self.model = model
    }

    func update(state: BridgeDesktopUIState, webView: WKWebView) {
      conversationObservation.observe(model?.conversation) { [weak self, weak webView] in
        guard let self, let model = self.model, let webView else { return }
        self.update(state: BridgeDesktopUIStateBuilder.build(from: model), webView: webView)
      }
      guard latestState != state else { return }
      latestRevision &+= 1
      latestState = state
      latestPatch = patchBuilder.makePatch(state: state, nextRevision: latestRevision)
      sendLatestPatch(to: webView)
    }

    func failLoading() {
      didFinishLoading = true
    }

    func userContentController(
      _ userContentController: WKUserContentController,
      didReceive message: WKScriptMessage
    ) {
      guard let envelope = decode(message.body) else { return }
      if envelope.command == .ready || envelope.command == .requestStateResync {
        guard let webView = message.webView else { return }
        sendFullSnapshot(to: webView)
        return
      }
      handle(envelope)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      didFinishLoading = true
      sendFullSnapshot(to: webView)
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

    private func sendLatestPatch(to webView: WKWebView) {
      let startedAt = ContinuousClock.now
      guard didFinishLoading, let latestState, let latestPatch,
        let data = try? JSONEncoder().encode(latestPatch),
        let json = String(data: data, encoding: .utf8)
      else { return }
      let script =
        "window.CodexBridgeDesktopUI && window.CodexBridgeDesktopUI.applyStatePatch(\(json))"
      webView.evaluateJavaScript(script, completionHandler: nil)
      ConversationPerformanceRecorder.shared.record(
        ConversationPerformanceSample(
          stage: .desktopStateEncode,
          duration: startedAt.duration(to: ContinuousClock.now),
          byteCount: data.count,
          entryCount: latestState.workbench?.selectedTask?.conversation.count ?? 0
        )
      )
    }

    private func sendFullSnapshot(to webView: WKWebView) {
      guard didFinishLoading, let latestState else { return }
      let patch = patchBuilder.fullSnapshot(state: latestState, revision: latestRevision)
      latestPatch = patch
      guard let data = try? JSONEncoder().encode(patch),
        let json = String(data: data, encoding: .utf8)
      else { return }
      let script =
        "window.CodexBridgeDesktopUI && window.CodexBridgeDesktopUI.applyStatePatch(\(json))"
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
