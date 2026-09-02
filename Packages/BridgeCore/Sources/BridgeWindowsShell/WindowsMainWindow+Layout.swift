#if os(Windows)
  import BridgeDesktopUI
  import WinSDK

  extension WindowsMainWindow {
    static func layout() {
      var area = RECT()
      guard GetClientRect(window, &area) else { return }
      desktopUI?.resize(to: area)
      if usesSharedDesktop {
        layoutSharedDesktop(in: area)
        return
      }
      let navigationWidth = Int32(WindowLayout.navigationWidth)
      WindowsNavigationSidebar.layout(height: area.bottom, width: navigationWidth)
      let detailBounds = RECT(
        left: navigationWidth,
        top: area.top,
        right: area.right,
        bottom: area.bottom
      )
      let contentBounds = WindowsPageHeader.layout(in: detailBounds)
      WindowsOverviewPane.layout(in: contentBounds)
      if selectedPage == .workbench {
        layoutWorkbench(in: contentBounds)
      } else {
        WindowsEmbeddedPages.layout(page: selectedPage, in: contentBounds)
      }
    }

    private static func layoutSharedDesktop(in bounds: RECT) {
      guard selectedPage == .workbench, let viewport = browserViewportSnapshot() else {
        hideChatViewport()
        return
      }
      chatBounds = browserViewportRect(viewport, in: bounds)
      chat?.resize(to: chatBounds)
      chat?.setVisible(viewport.visible && !isEmpty(chatBounds))
    }

    private static func hideChatViewport() {
      chatBounds = RECT()
      chat?.resize(to: RECT())
      chat?.setVisible(false)
    }

    private static func browserViewportRect(
      _ viewport: BridgeDesktopBrowserViewport,
      in bounds: RECT
    ) -> RECT {
      let scale = dpiScale()
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

    private static func dpiScale() -> Double {
      let dpi = window.map { GetDpiForWindow($0) } ?? 96
      return Double(dpi == 0 ? 96 : dpi) / 96
    }

    private static func finite(_ value: Double) -> Double {
      value.isFinite ? value : 0
    }

    private static func isEmpty(_ bounds: RECT) -> Bool {
      bounds.right <= bounds.left || bounds.bottom <= bounds.top
    }

    private static func layoutWorkbench(in bounds: RECT) {
      let width = bounds.right - bounds.left
      let inspectorWidth = min(
        Int32(WindowLayout.inspectorIdealWidth),
        max(Int32(WindowLayout.inspectorMinimumWidth), width / 3)
      )
      let inspector = RECT(
        left: bounds.right - inspectorWidth,
        top: bounds.top,
        right: bounds.right,
        bottom: bounds.bottom
      )
      let browser = RECT(
        left: bounds.left,
        top: bounds.top,
        right: inspector.left - 1,
        bottom: bounds.bottom
      )
      chatBounds = WindowsBrowserToolbar.layout(in: browser)
      WindowsTaskInspector.layoutChatPlaceholder(in: chatBounds)
      WindowsTaskInspector.layoutInspector(in: inspector)
      chat?.resize(to: chatBounds)
    }

    private static var usesSharedDesktop: Bool {
      desktopUI?.isReady == true
    }

    @discardableResult
    static func applySurfaceVisibility() -> Bool {
      let sharedDesktop = usesSharedDesktop
      guard sharedDesktop != sharedDesktopPresented else { return false }
      sharedDesktopPresented = sharedDesktop
      WindowsNavigationSidebar.setVisible(!sharedDesktop)
      WindowsPageHeader.setVisible(!sharedDesktop)
      WindowsOverviewPane.setVisible(!sharedDesktop && selectedPage == .overview)
      WindowsTaskInspector.setVisible(!sharedDesktop && selectedPage == .workbench)
      WindowsTaskInspector.setChatPlaceholderPageVisible(
        !sharedDesktop && selectedPage == .workbench)
      WindowsBrowserToolbar.setVisible(!sharedDesktop && selectedPage == .workbench)
      WindowsEmbeddedPages.setNativeVisible(!sharedDesktop)
      desktopUI?.setVisible(sharedDesktop)
      return true
    }
  }
#endif
