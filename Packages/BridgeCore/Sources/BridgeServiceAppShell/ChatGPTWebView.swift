import AppKit
import BridgeServiceAppCore
import SwiftUI
import WebKit

public struct ChatGPTWebView: NSViewRepresentable {
  public let site: ChatBrowserSite
  public let initialURL: URL
  public let reloadRequest: UInt64
  public let viewportSize: CGSize
  @Binding public var webViewReference: WKWebView?
  let onLoadError: (@MainActor (String?) -> Void)?
  let onNavigationChange: (@MainActor () -> Void)?

  public init(
    site: ChatBrowserSite = .chatGPT,
    initialURL: URL? = nil,
    reloadRequest: UInt64 = 0,
    viewportSize: CGSize = .zero,
    webViewReference: Binding<WKWebView?> = .constant(nil),
    onLoadError: (@MainActor (String?) -> Void)? = nil,
    onNavigationChange: (@MainActor () -> Void)? = nil
  ) {
    self.site = site
    self.initialURL = site.validatedURL(initialURL) ?? site.homeURL
    self.reloadRequest = reloadRequest
    self.viewportSize = viewportSize
    self._webViewReference = webViewReference
    self.onLoadError = onLoadError
    self.onNavigationChange = onNavigationChange
  }

  public func makeCoordinator() -> Coordinator {
    Coordinator(self)
  }

  public func sizeThatFits(
    _ proposal: ProposedViewSize,
    nsView: WKWebView,
    context: Context
  ) -> CGSize? {
    proposal.replacingUnspecifiedDimensions()
  }

  public func makeNSView(context: Context) -> WKWebView {
    let initialFrame = Self.safeFrame(for: NSRect(origin: .zero, size: viewportSize))

    // Reuse an existing instance (kept alive by the app model) so that leaving
    // and re-entering this view does not reload the page or lose its state.
    if let existing = webViewReference {
      prepareReusedWebView(existing, initialFrame: initialFrame, coordinator: context.coordinator)
      return existing
    }

    context.coordinator.parent = self
    let webView = Self.makeWebView(for: site, initialFrame: initialFrame)
    Self.attachDelegates(to: webView, coordinator: context.coordinator)
    webView.allowsBackForwardNavigationGestures = true
    loadInitialURL(in: webView, coordinator: context.coordinator)

    DispatchQueue.main.async { [weak webView] in
      guard let webView else { return }
      self.webViewReference = webView
    }

    return webView
  }

  public func updateNSView(_ nsView: WKWebView, context: Context) {
    updateWebView(nsView, coordinator: context.coordinator)
  }

  func prepareReusedWebView(
    _ webView: WKWebView,
    initialFrame: NSRect,
    coordinator: Coordinator
  ) {
    coordinator.parent = self
    Self.attachDelegates(to: webView, coordinator: coordinator)
    webView.autoresizingMask = [.width, .height]
    if webView.frame.size.width < 1 || webView.frame.size.height < 1 {
      webView.frame = Self.safeFrame(for: initialFrame)
    }
    if webView.url == nil && !webView.isLoading {
      loadInitialURL(in: webView, coordinator: coordinator)
    } else if webView.url != nil && !webView.isLoading {
      Self.setDrawsBackground(true, on: webView)
    }
  }

  func updateWebView(_ nsView: WKWebView, coordinator: Coordinator) {
    coordinator.parent = self
    Self.attachDelegates(to: nsView, coordinator: coordinator)
    nsView.autoresizingMask = [.width, .height]
    if nsView.frame.size.width < 1 || nsView.frame.size.height < 1 {
      nsView.frame = Self.safeFrame(for: NSRect(origin: .zero, size: viewportSize))
    }
    if coordinator.consumeReloadRequest(reloadRequest) {
      if nsView.url == nil {
        loadInitialURL(
          in: nsView,
          coordinator: coordinator,
          cachePolicy: .reloadRevalidatingCacheData
        )
      } else {
        coordinator.resetLoadFailure()
        nsView.reloadFromOrigin()
      }
      return
    }
    if nsView.url == nil && !nsView.isLoading && !coordinator.hasLoadFailure {
      loadInitialURL(in: nsView, coordinator: coordinator)
    }
  }

  func loadInitialURL(
    in webView: WKWebView,
    coordinator: Coordinator,
    cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy
  ) {
    coordinator.resetLoadFailure()
    Self.setDrawsBackground(false, on: webView)
    let request = URLRequest(
      url: initialURL,
      cachePolicy: cachePolicy,
      timeoutInterval: 30
    )
    webView.load(request)
  }

  static func attachDelegates(to webView: WKWebView, coordinator: Coordinator) {
    webView.navigationDelegate = coordinator
    webView.uiDelegate = coordinator
    if let browserWebView = webView as? ChatBrowserWKWebView {
      browserWebView.onDidMoveToWindow = { [weak coordinator] attachedWebView in
        guard let coordinator, attachedWebView.navigationDelegate === coordinator else { return }
        attachedWebView.needsLayout = true
        attachedWebView.needsDisplay = true
        if attachedWebView.url == nil && !attachedWebView.isLoading && !coordinator.hasLoadFailure {
          coordinator.parent.loadInitialURL(in: attachedWebView, coordinator: coordinator)
        }
      }
    }
  }

  public final class Coordinator: NSObject, WKDownloadDelegate, WKNavigationDelegate, WKUIDelegate {
    var parent: ChatGPTWebView
    private var handledReloadRequest: UInt64
    private(set) var hasLoadFailure = false
    private var downloadDestinations: [ObjectIdentifier: DownloadDestination] = [:]

    private struct DownloadDestination {
      let target: URL
      let temporary: URL
    }

    init(_ parent: ChatGPTWebView) {
      self.parent = parent
      handledReloadRequest = parent.reloadRequest
    }

    func resetLoadFailure() {
      hasLoadFailure = false
    }

    func consumeReloadRequest(_ request: UInt64) -> Bool {
      guard request != handledReloadRequest else { return false }
      handledReloadRequest = request
      return true
    }

    // Direct new-window navigations back into the same WKWebView. Download
    // requests still pass through the navigation delegate, which converts them
    // to WKDownload without handing them to an external browser.
    public func webView(
      _ webView: WKWebView,
      createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction,
      windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
      guard Self.allows(navigationAction) else { return nil }
      if navigationAction.shouldPerformDownload {
        webView.startDownload(using: navigationAction.request) { [weak self] download in
          download.delegate = self
        }
        return nil
      }
      webView.load(navigationAction.request)
      return nil
    }

    // Block external URL schemes (e.g. chatgpt:// or x-webkit-app-launch://) so
    // WKWebView never hands login navigation to LaunchServices. http(s) stays
    // in-process; blob/data URLs are accepted only when WebKit marks them as a
    // download.
    //
    // NOTE: implemented as the async variant because this SDK's WKNavigationDelegate
    // imports the requirement via WK_SWIFT_ASYNC; the decisionHandler-style method
    // is not exposed to ObjC (WebKit then treats it as unimplemented and allows
    // every navigation, including external-scheme handoff to Safari Web Apps).
    public func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
      guard Self.allows(navigationAction) else {
        return (.cancel, preferences)
      }
      if navigationAction.shouldPerformDownload {
        return (.download, preferences)
      }
      return (.allow, preferences)
    }

    public func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
      Self.shouldDownload(navigationResponse) ? .download : .allow
    }

    public func webView(
      _ webView: WKWebView,
      navigationAction: WKNavigationAction,
      didBecome download: WKDownload
    ) {
      download.delegate = self
    }

    public func webView(
      _ webView: WKWebView,
      navigationResponse: WKNavigationResponse,
      didBecome download: WKDownload
    ) {
      download.delegate = self
    }

    public func download(
      _ download: WKDownload,
      decideDestinationUsing response: URLResponse,
      suggestedFilename: String
    ) async -> URL? {
      let panel = NSSavePanel()
      panel.title = "保存下载文件"
      panel.prompt = "下载"
      panel.nameFieldStringValue = Self.safeFilename(suggestedFilename)
      panel.canCreateDirectories = true
      guard await panel.begin() == .OK else { return nil }
      guard let target = panel.url,
        let temporary = Self.temporaryDestination(for: target)
      else {
        return nil
      }
      downloadDestinations[ObjectIdentifier(download)] = DownloadDestination(
        target: target,
        temporary: temporary
      )
      return temporary
    }

    public func downloadDidFinish(_ download: WKDownload) {
      guard let destination = downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
      else {
        return
      }
      do {
        try Self.replaceDownloadedFile(
          temporary: destination.temporary,
          target: destination.target
        )
      } catch {
        try? FileManager.default.removeItem(at: destination.temporary)
      }
    }

    public func download(
      _ download: WKDownload,
      didFailWithError error: Error,
      resumeData: Data?
    ) {
      guard let destination = downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
      else {
        return
      }
      try? FileManager.default.removeItem(at: destination.temporary)
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
      handleNavigationCommit(in: webView)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      handleNavigationCommit(in: webView)
    }

    public func webView(
      _ webView: WKWebView,
      didFailProvisionalNavigation navigation: WKNavigation!,
      withError error: any Error
    ) {
      handleNavigationFailure(error, in: webView)
    }

    public func webView(
      _ webView: WKWebView,
      didFail navigation: WKNavigation!,
      withError error: any Error
    ) {
      handleNavigationFailure(error, in: webView)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      handleWebContentProcessDidTerminate(in: webView)
    }

    func handleNavigationCommit(in webView: WKWebView) {
      hasLoadFailure = false
      ChatGPTWebView.setDrawsBackground(true, on: webView)
      parent.onLoadError?(nil)
      parent.onNavigationChange?()
    }

    func handleNavigationFailure(_ error: any Error, in webView: WKWebView) {
      guard !Self.shouldIgnoreNavigationError(error) else { return }
      hasLoadFailure = true
      ChatGPTWebView.setDrawsBackground(false, on: webView)
      parent.onLoadError?(Self.loadErrorMessage(for: parent.site, error: error))
    }

    func handleWebContentProcessDidTerminate(in webView: WKWebView) {
      hasLoadFailure = false
      ChatGPTWebView.setDrawsBackground(false, on: webView)
      parent.onLoadError?(nil)
      if webView.url == nil {
        parent.loadInitialURL(in: webView, coordinator: self)
      } else {
        webView.reload()
      }
    }

    static func shouldIgnoreNavigationError(_ error: any Error) -> Bool {
      let nsError = error as NSError
      if nsError.code == NSURLErrorCancelled { return true }
      return nsError.domain == "WebKitErrorDomain" && nsError.code == 102
    }

    static func loadErrorMessage(for site: ChatBrowserSite, error: any Error) -> String {
      let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
      if detail.isEmpty {
        return "无法加载 \(site.displayName)，请检查网络或代理后点击刷新或外部打开。"
      }
      return "无法加载 \(site.displayName)：\(detail)，请检查网络或代理后点击刷新或外部打开。"
    }

    static func safeFilename(_ suggestedFilename: String) -> String {
      let filename = (suggestedFilename as NSString).lastPathComponent
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return filename.isEmpty || filename == "." ? "下载文件" : filename
    }

    static func shouldDownload(_ navigationResponse: WKNavigationResponse) -> Bool {
      shouldDownload(
        canShowMIMEType: navigationResponse.canShowMIMEType,
        response: navigationResponse.response)
    }

    static func shouldDownload(canShowMIMEType: Bool, response: URLResponse) -> Bool {
      if !canShowMIMEType { return true }
      guard let response = response as? HTTPURLResponse else { return false }
      return response.value(forHTTPHeaderField: "Content-Disposition")?
        .lowercased()
        .contains("attachment") == true
    }

    private static func allows(_ navigationAction: WKNavigationAction) -> Bool {
      guard let scheme = navigationAction.request.url?.scheme?.lowercased() else { return false }
      if scheme == "http" || scheme == "https" { return true }
      return navigationAction.shouldPerformDownload && (scheme == "blob" || scheme == "data")
    }

    static func temporaryDestination(for target: URL) -> URL? {
      let directory = target.deletingLastPathComponent()
      guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
      let temporary = directory.appendingPathComponent(
        ".codexbridge-download-\(UUID().uuidString.lowercased())",
        isDirectory: false
      )
      return FileManager.default.fileExists(atPath: temporary.path) ? nil : temporary
    }

    static func replaceDownloadedFile(temporary: URL, target: URL) throws {
      guard FileManager.default.fileExists(atPath: temporary.path) else { return }
      if FileManager.default.fileExists(atPath: target.path) {
        _ = try FileManager.default.replaceItemAt(
          target,
          withItemAt: temporary,
          backupItemName: nil,
          options: []
        )
      } else {
        try FileManager.default.moveItem(at: temporary, to: target)
      }
    }
  }
}
