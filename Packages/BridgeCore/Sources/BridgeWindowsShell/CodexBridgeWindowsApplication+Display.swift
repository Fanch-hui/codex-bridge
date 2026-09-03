#if os(Windows)
  import BridgeDesktopUI
  import Foundation
  import WinSDK

  private struct WindowsDesktopRenderSnapshot: Equatable, Sendable {
    let state: BridgeDesktopUIState
    let chatSlotEnabled: Bool
    let runningTaskCount: Int
    let pendingApprovalCount: Int
    let desktopState: WindowsChatWebView.State
    let desktopErrorDetail: String?
    let desktopReady: Bool
    let desktopLoadStalled: Bool
  }

  @MainActor
  private var lastWindowsDesktopRenderSnapshot: WindowsDesktopRenderSnapshot? = nil

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
      let chatSlotEnabled = chat.state == .active && display.browserEnabled
      let state = WindowsDesktopUIStateBuilder.build(
        workbench: display,
        management: managementDisplay,
        workspace: auxiliarySnapshot.workspace,
        logs: auxiliarySnapshot.logs,
        connections: auxiliarySnapshot.connections,
        settings: auxiliarySnapshot.settings,
        agentDefaults: auxiliarySnapshot.agentDefaults,
        selectedNavigation: selectedPage.desktopNavigation,
        browserAvailable: chat.state == .active,
        browserStatus: browserStatus(for: chat),
        browserCanGoBack: chat.canGoBack,
        browserCanGoForward: chat.canGoForward,
        feedback: model.feedback.current
      )
      let snapshot = WindowsDesktopRenderSnapshot(
        state: state,
        chatSlotEnabled: chatSlotEnabled,
        runningTaskCount: display.runningTaskCount,
        pendingApprovalCount: display.pendingApprovalCount,
        desktopState: desktopUI.state,
        desktopErrorDetail: desktopUI.errorDetail,
        desktopReady: desktopUI.isReady,
        desktopLoadStalled: desktopUI.loadStalled
      )
      guard snapshot != lastWindowsDesktopRenderSnapshot else { return }
      lastWindowsDesktopRenderSnapshot = snapshot
      WindowsUIThread.shared.enqueue {
        applyOnUI(
          snapshot: snapshot,
          desktopUI: desktopUI
        )
      }
    }

    private nonisolated static func applyOnUI(
      snapshot: WindowsDesktopRenderSnapshot,
      desktopUI: WindowsDesktopUIWebView
    ) {
      desktopUI.setState(snapshot.state)
      WindowsMainWindow.setChatSlotEnabled(snapshot.chatSlotEnabled)
      WindowsMainWindowChrome.updateStatus(
        connectionLabel: snapshot.state.connectionLabel,
        runningTasks: snapshot.runningTaskCount,
        pendingApprovals: snapshot.pendingApprovalCount
      )
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
