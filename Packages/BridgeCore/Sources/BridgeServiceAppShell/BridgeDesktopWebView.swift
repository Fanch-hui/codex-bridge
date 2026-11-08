import AppKit
import BridgeDesktopUI
import Foundation
import SwiftUI
import WebKit

struct BridgeDesktopWebView: NSViewRepresentable {
  @ObservedObject var model: BridgeServiceAppModel
  var surface: BridgeDesktopSurface = .main

  static let websiteDataStoreIdentifier = UUID(
    uuid: (
      0x63, 0x6F, 0x64, 0x65, 0x78, 0x62, 0x72, 0x69,
      0x64, 0x67, 0x65, 0x64, 0x65, 0x73, 0x6B, 0x31
    ))

  static func websiteDataStore() -> WKWebsiteDataStore {
    WKWebsiteDataStore(forIdentifier: websiteDataStoreIdentifier)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(model: model, surface: surface)
  }

  func makeNSView(context: Context) -> WKWebView {
    let userContentController = WKUserContentController()
    userContentController.add(context.coordinator, name: "bridgeDesktopUI")

    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = Self.websiteDataStore()
    configuration.userContentController = userContentController
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    let webView = WKWebView(frame: .zero, configuration: configuration)
    context.coordinator.attach(webView)
    webView.navigationDelegate = context.coordinator
    webView.uiDelegate = context.coordinator
    webView.setValue(false, forKey: "drawsBackground")

    guard let indexURL = BridgeDesktopUI.indexURL() else {
      context.coordinator.failLoading()
      return webView
    }
    var components = URLComponents(url: indexURL, resolvingAgainstBaseURL: false)
    if surface == .preferences {
      components?.queryItems = [URLQueryItem(name: "surface", value: "preferences")]
    }
    webView.loadFileURL(
      components?.url ?? indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
    context.coordinator.update(
      state: context.coordinator.buildState(from: model),
      webView: webView
    )
    return webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {
    context.coordinator.requestUpdate()
  }

  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    weak var model: BridgeServiceAppModel?
    private(set) weak var webView: WKWebView?
    let surface: BridgeDesktopSurface
    private var latestState: BridgeDesktopUIState?
    private var latestPatch: BridgeDesktopUIStatePatch?
    private var latestRevision: UInt64 = 0
    private var patchBuilder = BridgeDesktopUIStatePatchBuilder()
    private var didFinishLoading = false
    private var newConversationRequestInFlight: UUID?
    private var destinationRequestInFlight: UUID?
    private let conversationObservation = DesktopConversationObservation()
    private let updateThrottle = DesktopUpdateThrottle()
    private let stateCache = BridgeDesktopUIStateCache()

    init(model: BridgeServiceAppModel, surface: BridgeDesktopSurface = .main) {
      self.model = model
      self.surface = surface
      super.init()
      if surface == .preferences {
        NotificationCenter.default.addObserver(
          self, selector: #selector(windowDidBecomeKey(_:)),
          name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(
          self, selector: #selector(windowWillClose(_:)),
          name: NSWindow.willCloseNotification, object: nil)
      }
    }

    func attach(_ webView: WKWebView) {
      self.webView = webView
      BridgeDesktopWindowCoordinator.shared.attach(self, surface: surface)
      if surface == .preferences {
        DispatchQueue.main.async { [weak self] in
          self?.model?.preferencesWindowIsKey = self?.webView?.window?.isKeyWindow == true
        }
      }
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
      guard let window = notification.object as? NSWindow else { return }
      let isPreferences = window === webView?.window
      model?.preferencesWindowIsKey = isPreferences
      if isPreferences {
        model?.preferencesWindowDidAppear()
        requestUpdate()
      }
    }

    @objc private func windowWillClose(_ notification: Notification) {
      guard let window = notification.object as? NSWindow, window === webView?.window else {
        return
      }
      model?.preferencesWindowDidDisappear()
    }

    func buildState(from model: BridgeServiceAppModel) -> BridgeDesktopUIState {
      BridgeDesktopUIStateBuilder.build(
        from: model,
        selectionOverride: surface == .preferences ? model.preferencesNavigation : nil,
        includeWorkbench: surface == .main,
        cache: stateCache)
    }

    /// SwiftUI calls `updateNSView` for every model change, most of which never reach the page.
    /// The state is built from the model's latest values once per throttle window, not per call.
    func requestUpdate() {
      updateThrottle.schedule { [weak self] in self?.refreshFromModel() }
    }

    private func refreshFromModel() {
      guard let model, let webView else { return }
      if surface == .preferences, !model.preferencesWindowIsVisible, latestState != nil {
        return
      }
      update(state: buildState(from: model), webView: webView)
    }

    func update(state: BridgeDesktopUIState, webView: WKWebView) {
      defer {
        if surface == .main { sendRequestedConversation(to: webView) }
      }
      if surface == .main {
        conversationObservation.observe(model?.conversation) { [weak self] in
          self?.refreshFromModel()
        }
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
      if surface == .main { webView.window?.isMovableByWindowBackground = true }
      sendFullSnapshot(to: webView)
      if surface == .main { sendRequestedConversation(to: webView) }
    }

    private func sendRequestedConversation(to webView: WKWebView) {
      guard didFinishLoading, newConversationRequestInFlight == nil,
        let requestID = model?.pendingNewConversationRequestID
      else { return }
      newConversationRequestInFlight = requestID
      let script =
        "Boolean(window.CodexBridgeDesktopDSHWorkbench?.openConversation())"
      webView.evaluateJavaScript(script) { [weak self, weak webView] value, error in
        guard let self else { return }
        self.newConversationRequestInFlight = nil
        if (value as? Bool) == true {
          self.model?.acknowledgeNewConversation(requestID)
        } else if error != nil {
          self.model?.acknowledgeNewConversation(requestID)
          self.model?.errorMessage = "无法打开新对话，请重新打开工作台。"
        }
        if let pending = self.model?.pendingNewConversationRequestID,
          pending != requestID, let webView
        {
          self.sendRequestedConversation(to: webView)
        }
      }
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
      navigationAction.request.url?.isFileURL == true ? .allow : .cancel
    }

    deinit {
      NotificationCenter.default.removeObserver(self)
    }

    private func sendLatestPatch(to webView: WKWebView) {
      let startedAt = ContinuousClock.now
      guard didFinishLoading, let latestState, let latestPatch,
        let data = try? JSONEncoder().encode(latestPatch),
        let json = String(data: data, encoding: .utf8)
      else { return }
      let script =
        "window.CodexBridgeDesktopUI && window.CodexBridgeDesktopUI.applyStatePatch(\(json))"
      webView.evaluateJavaScript(script) { [weak self] _, error in
        guard error == nil else { return }
        self?.sendPendingDestination()
      }
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
      webView.evaluateJavaScript(script) { [weak self] _, error in
        guard error == nil else { return }
        self?.sendPendingDestination()
      }
    }

    func sendPendingDestination() {
      guard didFinishLoading, destinationRequestInFlight == nil, let webView,
        let destination = BridgeDesktopWindowCoordinator.shared.pendingDestination(for: surface),
        let script = destination.script
      else { return }
      destinationRequestInFlight = destination.id
      webView.evaluateJavaScript(script) { [weak self] value, error in
        guard let self else { return }
        self.destinationRequestInFlight = nil
        if error == nil, (value as? Bool) == true {
          BridgeDesktopWindowCoordinator.shared.completeDestination(
            destination.id, surface: self.surface)
        }
        if let pending = BridgeDesktopWindowCoordinator.shared.pendingDestination(
          for: self.surface),
          pending.id != destination.id
        {
          self.sendPendingDestination()
        }
      }
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
      Task { @MainActor [weak self, weak model] in
        guard let self, let model else { return }
        self.route(envelope, model: model)
      }
    }

  }
}
