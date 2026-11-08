import AppKit
import WebKit

extension BridgeDesktopWebView.Coordinator: WKUIDelegate {
  func webView(
    _ webView: WKWebView,
    runOpenPanelWith parameters: WKOpenPanelParameters,
    initiatedByFrame frame: WKFrameInfo
  ) async -> [URL]? {
    guard frame.request.url?.isFileURL == true, let window = webView.window else { return nil }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = parameters.allowsDirectories
    panel.canChooseFiles = !parameters.allowsDirectories
    panel.allowsMultipleSelection = parameters.allowsMultipleSelection
    return await panel.beginSheetModal(for: window) == .OK ? panel.urls : nil
  }

  func webView(
    _ webView: WKWebView,
    runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo
  ) async -> Bool {
    guard frame.request.url?.isFileURL == true, let window = webView.window else { return false }
    let alert = NSAlert()
    alert.messageText = "确认操作"
    alert.informativeText = message
    alert.addButton(withTitle: "确认")
    alert.addButton(withTitle: "取消")
    return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
  }
}
