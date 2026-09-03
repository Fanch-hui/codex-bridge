#if os(Windows)
  import BridgeDesktopUI
  import WinSDK

  extension WindowsMainWindow {
    static func layout() {
      var area = RECT()
      guard GetClientRect(window, &area) else { return }
      desktopUI?.resize(to: area)
      WindowsShellFailure.layout(in: area)
      layoutChat(in: area)
    }

    /// The chat surface is placed by the page's reported viewport; the host only
    /// adds the window offset and the model-side enable switch.
    private static func layoutChat(in bounds: RECT) {
      let viewport = renderedPage == .workbench ? browserViewportSnapshot() : nil
      guard chatSlotEnabled, let viewport, viewport.visible else {
        hideChat()
        return
      }
      chatBounds = browserViewportRect(viewport, in: bounds)
      let visible = !isEmpty(chatBounds)
      chat?.resize(to: chatBounds)
      chat?.setVisible(visible)
      if visible {
        chat?.bringToTop()
      }
    }

    private static func hideChat() {
      chatBounds = RECT()
      chat?.resize(to: RECT())
      chat?.setVisible(false)
    }

    static func browserViewportRect(
      _ viewport: BridgeDesktopBrowserViewport,
      in bounds: RECT,
      dpi overrideDpi: UINT? = nil
    ) -> RECT {
      let scale = dpiScale(overrideDpi: overrideDpi)
      let width = Double(max(Int32(0), bounds.right - bounds.left))
      let height = Double(max(Int32(0), bounds.bottom - bounds.top))
      let x = min(width, max(0, finite(viewport.x) * scale))
      let y = min(height, max(0, finite(viewport.y) * scale))
      let right = min(width, max(x, x + max(0, finite(viewport.width) * scale)))
      let bottom = min(height, max(y, y + max(0, finite(viewport.height) * scale)))
      return RECT(
        left: bounds.left + Int32(x.rounded(.down)),
        top: bounds.top + Int32(y.rounded(.down)),
        right: bounds.left + Int32(right.rounded(.down)),
        bottom: bounds.top + Int32(bottom.rounded(.down))
      )
    }

    private static func dpiScale(overrideDpi: UINT? = nil) -> Double {
      let dpi = overrideDpi ?? window.map { GetDpiForWindow($0) } ?? 96
      return Double(dpi == 0 ? 96 : dpi) / 96
    }

    private static func finite(_ value: Double) -> Double {
      value.isFinite ? value : 0
    }

    private static func isEmpty(_ bounds: RECT) -> Bool {
      bounds.right <= bounds.left || bounds.bottom <= bounds.top
    }
  }
#endif
