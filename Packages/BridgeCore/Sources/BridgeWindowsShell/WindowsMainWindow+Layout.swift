#if os(Windows)
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
      guard selectedPage == .workbench else {
        chatBounds = RECT()
        chat?.resize(to: RECT())
        chat?.setVisible(false)
        return
      }
      let width = max(Int32(0), bounds.right - bounds.left)
      let chatWidth = min(Int32(520), max(Int32(360), width / 3))
      chatBounds = RECT(
        left: max(bounds.left, bounds.right - chatWidth),
        top: bounds.top,
        right: bounds.right,
        bottom: bounds.bottom
      )
      chat?.resize(to: chatBounds)
      chat?.setVisible(true)
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
