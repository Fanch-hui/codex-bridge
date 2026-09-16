#if os(Windows)
  import Foundation

  extension CodexBridgeWindowsApplication {
    private static var trayMemoryTask: Task<Void, Never>?
    private static var isWindowVisible = true
    private static var isLongTermHidden = false

    static func updateWindowVisibility(_ visible: Bool, model: WindowsWorkbenchModel) {
      model.setWindowVisible(visible)
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
      WindowsUIThread.shared.chatWebView()?.setLowMemoryUsage(
        !model.isChatBrowserEnabled || isLongTermHidden)
    }

    static func stopActivityScheduling() {
      trayMemoryTask?.cancel()
      trayMemoryTask = nil
    }
  }
#endif
