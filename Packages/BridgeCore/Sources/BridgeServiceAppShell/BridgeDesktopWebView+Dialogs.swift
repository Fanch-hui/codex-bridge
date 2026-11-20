import AppKit
import WebKit

extension BridgeDesktopWebView.Coordinator: WKUIDelegate {
  private func isTrustedFileFrame(_ frame: WKFrameInfo, in webView: WKWebView) -> Bool {
    if frame.request.url?.isFileURL == true {
      return true
    }
    return frame.isMainFrame && webView.url?.isFileURL == true
  }

  func webView(
    _ webView: WKWebView,
    runOpenPanelWith parameters: WKOpenPanelParameters,
    initiatedByFrame frame: WKFrameInfo
  ) async -> [URL]? {
    guard isTrustedFileFrame(frame, in: webView), let window = webView.window else { return nil }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = parameters.allowsDirectories
    panel.canChooseFiles = !parameters.allowsDirectories
    panel.allowsMultipleSelection = parameters.allowsMultipleSelection
    return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
  }

  func webView(
    _ webView: WKWebView,
    runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo
  ) async {
    guard isTrustedFileFrame(frame, in: webView), let window = webView.window else { return }
    let alert = NSAlert()
    alert.messageText = "提示"
    alert.informativeText = message
    alert.addButton(withTitle: "好")
    _ = await alert.beginSheetModal(for: window)
  }

  func webView(
    _ webView: WKWebView,
    runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo
  ) async -> Bool {
    guard isTrustedFileFrame(frame, in: webView), let window = webView.window else { return false }
    let alert = NSAlert()
    alert.messageText = "确认操作"
    alert.informativeText = message
    alert.addButton(withTitle: "确认")
    alert.addButton(withTitle: "取消")
    return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
  }
}
