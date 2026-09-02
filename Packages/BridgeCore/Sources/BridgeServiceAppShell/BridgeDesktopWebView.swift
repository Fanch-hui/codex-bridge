import AppKit
import BridgeDesktopUI
import Foundation
import SwiftUI
import WebKit

struct BridgeDesktopWebView: NSViewRepresentable {
  enum Mode: Equatable {
    case overview
    case navigationOnly
  }

  @ObservedObject var model: BridgeServiceAppModel
  let mode: Mode

  func makeCoordinator() -> Coordinator {
    Coordinator(model: model, mode: mode)
  }

  func makeNSView(context: Context) -> WKWebView {
    let userContentController = WKUserContentController()
    userContentController.add(context.coordinator, name: "bridgeDesktopUI")
    if mode == .navigationOnly {
      userContentController.addUserScript(
        WKUserScript(
          source: Coordinator.navigationOnlyStyleUserScript,
          injectionTime: .atDocumentStart,
          forMainFrameOnly: true
        )
      )
    }

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
      mode: mode,
      webView: webView
    )
    return webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {
    context.coordinator.update(
      state: BridgeDesktopUIStateBuilder.build(from: model),
      mode: mode,
      webView: nsView
    )
  }

  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    weak var model: BridgeServiceAppModel?
    private var mode: Mode
    private var latestState: BridgeDesktopUIState?
    private var didFinishLoading = false

    init(model: BridgeServiceAppModel, mode: Mode) {
      self.model = model
      self.mode = mode
    }

    func update(state: BridgeDesktopUIState, mode: Mode, webView: WKWebView) {
      if self.mode != mode {
        self.mode = mode
        applyMode(to: webView)
      }
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
      applyMode(to: webView)
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

    private func applyMode(to webView: WKWebView) {
      let script =
        mode == .navigationOnly
        ? Self.navigationOnlyStyleApplication
        : Self.fullPageStyleApplication
      webView.evaluateJavaScript(script, completionHandler: nil)
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
      switch envelope.command {
      case .ready:
        return
      case .refresh:
        model.refresh()
      case .selectPage:
        guard let navigation = envelope.payload.navigation else { return }
        select(navigation, in: model)
      case .openWorkbench:
        model.selection = .workbench
      case .openProjects:
        model.selection = .projects
      case .openConnections:
        model.selection = .connections
      case .openSettings:
        model.selection = .settings
      case .openLogs:
        model.selection = .logs
      case .openTask:
        guard let taskID = envelope.payload.taskID,
          !taskID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          taskID.count <= 256
        else { return }
        model.openTask(taskID)
        model.selection = .workbench
      }
    }

    private func select(_ navigation: BridgeDesktopNavigation, in model: BridgeServiceAppModel) {
      model.selection = BridgeServiceNavigation(rawValue: navigation.rawValue)
    }

    static let navigationOnlyStyle = """
      html, body { min-width: 0 !important; overflow: hidden !important; }
      .app-shell { display: block !important; min-height: 100vh !important; }
      .sidebar { width: 100% !important; min-height: 100vh !important; }
      .main-shell { display: none !important; }
      """

    static let navigationOnlyStyleUserScript = """
      (function() {
        var style = document.createElement('style');
        style.id = 'bridge-desktop-navigation-only';
        style.textContent = `\(navigationOnlyStyle)`;
        (document.head || document.documentElement).appendChild(style);
      }())
      """

    static let navigationOnlyStyleApplication = """
      (function() {
        var style = document.getElementById('bridge-desktop-navigation-only');
        if (!style) {
          style = document.createElement('style');
          style.id = 'bridge-desktop-navigation-only';
          style.textContent = `\(navigationOnlyStyle)`;
          document.head.appendChild(style);
        }
      }())
      """

    static let fullPageStyleApplication = """
      (function() {
        var style = document.getElementById('bridge-desktop-navigation-only');
        if (style) style.remove();
      }())
      """
  }
}
