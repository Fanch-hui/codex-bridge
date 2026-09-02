#if os(Windows)
  import Foundation
  import WinSDK

  extension CodexBridgeWindowsApplication {
    static func applyDisplay(
      model: WindowsWorkbenchModel,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime,
      chat: WindowsChatWebView,
      desktopUI: WindowsDesktopUIWebView
    ) {
      model.refreshDisplaySnapshot()
      management.refreshDisplaySnapshot()
      let auxiliarySnapshot = auxiliary.desktopDisplaySnapshot()
      let display = model.displayBox.current()
      let managementDisplay = management.displayBox.current()
      WindowsUIThread.shared.enqueue {
        applyOnUI(
          workbench: display,
          management: managementDisplay,
          auxiliary: auxiliarySnapshot,
          chat: chat,
          desktopUI: desktopUI
        )
      }
    }

    private nonisolated static func applyOnUI(
      workbench: WindowsWorkbenchDisplay,
      management: WindowsManagementDisplay,
      auxiliary: WindowsAuxiliaryDisplaySnapshot,
      chat: WindowsChatWebView,
      desktopUI: WindowsDesktopUIWebView
    ) {
      desktopUI.setState(
        WindowsDesktopUIStateBuilder.build(
          workbench: workbench,
          management: management,
          workspace: auxiliary.workspace,
          logs: auxiliary.logs,
          connections: auxiliary.connections,
          settings: auxiliary.settings,
          agentDefaults: auxiliary.agentDefaults,
          selectedNavigation: WindowsMainWindow.currentPage().desktopNavigation,
          browserAvailable: chat.state == .active,
          browserStatus: browserStatus(for: chat)
        )
      )
      WindowsMainWindow.setChatSlotEnabled(chat.state == .active && workbench.browserEnabled)
      WindowsMainWindow.refreshSurfaces()
    }

    private nonisolated static func browserStatus(for chat: WindowsChatWebView) -> String? {
      switch chat.state {
      case .active:
        return nil
      case .loading:
        return "正在加载聊天页…"
      case .failed:
        return hostBrowserFailure("聊天页加载失败", chat)
      case .unsupported:
        return hostBrowserFailure("内置浏览器不可用", chat)
      }
    }

    private nonisolated static func hostBrowserFailure(
      _ reason: String,
      _ chat: WindowsChatWebView
    ) -> String {
      let detail = chat.errorDetail ?? "未知原因"
      return "\(reason)：\(detail)。可使用“在外部浏览器打开”，任务管理功能仍然可用。"
    }

    nonisolated static func openChatExternally() {
      "open".withCString(encodedAs: UTF16.self) { operation in
        WindowsChatWebView.chatURL.withCString(encodedAs: UTF16.self) { url in
          _ = ShellExecuteW(
            WindowsMainWindow.currentWindow(), operation, url, nil, nil, SW_SHOWNORMAL)
        }
      }
    }
  }
#endif
