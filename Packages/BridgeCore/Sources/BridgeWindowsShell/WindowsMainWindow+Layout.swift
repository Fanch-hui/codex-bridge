#if os(Windows)
  import WinSDK

  extension WindowsMainWindow {
    static func layout() {
      var area = RECT()
      guard GetClientRect(window, &area) else { return }
      desktopUI?.resize(to: area)
      if usesSharedOverview { return }
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

    private static var usesSharedOverview: Bool {
      selectedPage == .overview && desktopUI?.isReady == true
    }

    @discardableResult
    static func applySurfaceVisibility() -> Bool {
      let sharedOverview = usesSharedOverview
      guard sharedOverview != sharedOverviewPresented else { return false }
      sharedOverviewPresented = sharedOverview
      WindowsNavigationSidebar.setVisible(!sharedOverview)
      WindowsPageHeader.setVisible(!sharedOverview)
      WindowsOverviewPane.setVisible(selectedPage == .overview && !sharedOverview)
      desktopUI?.setVisible(sharedOverview)
      return true
    }
  }
#endif
