#if os(Windows)
  import Foundation

  extension CodexBridgeDesktopApplication {
    private static var trayMemoryTask: Task<Void, Never>?
    private static var isWindowVisible = true
    private static var isLongTermHidden = false

    static func updateWindowVisibility(_ visible: Bool, model: WindowsWorkbenchModel) {
      model.setWindowVisible(visible)
      messageCenter?.setForegroundVisible(visible)
      guard visible != isWindowVisible else { return }
      isWindowVisible = visible
      isLongTermHidden = false
      trayMemoryTask?.cancel()
      trayMemoryTask = nil
      updateBrowserMemoryPolicy(model: model)
      guard !visible else { return }
      trayMemoryTask = Task { [weak model] in
        do {
          try await Task.sleep(for: .seconds(60))
        } catch {
          return
        }
        guard let model, !model.isShuttingDown, !isWindowVisible else { return }
        isLongTermHidden = true
        updateBrowserMemoryPolicy(model: model)
      }
    }

    static func updateBrowserMemoryPolicy(model: WindowsWorkbenchModel) {
      guard let browser = WindowsUIThread.shared.chatWebView() else { return }
      browser.setEnabled(model.isChatBrowserEnabled)
      browser.setLowMemoryUsage(isLongTermHidden)
    }

    static func stopActivityScheduling() {
      trayMemoryTask?.cancel()
      trayMemoryTask = nil
    }
  }
#endif
