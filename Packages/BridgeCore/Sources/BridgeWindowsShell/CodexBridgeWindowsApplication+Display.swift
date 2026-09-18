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

  private struct WindowsDesktopRenderInputs: Equatable {
    let revisions: [UInt64]
    let page: WindowsMainPage
    let feedback: BridgeDesktopFeedback?
    let chatState: WindowsChatWebView.State
    let chatURL: String?
    let chatError: String?
    let canGoBack: Bool
    let canGoForward: Bool
    let desktopState: WindowsChatWebView.State
    let desktopError: String?
    let desktopReady: Bool
    let desktopLoadStalled: Bool
  }

  @MainActor
  private var lastWindowsDesktopRenderInputs: WindowsDesktopRenderInputs?

  @MainActor
  private var lastWorkbenchServiceRevision: UInt64?

  extension CodexBridgeWindowsApplication {
    static func applyDisplay(
      model: WindowsWorkbenchModel,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime,
      chat: WindowsChatWebView,
      desktopUI: WindowsDesktopUIWebView
    ) {
      let workbenchRevision = model.displayBox.revision
      if workbenchRevision != lastWorkbenchServiceRevision {
        lastWorkbenchServiceRevision = workbenchRevision
        auxiliary.connections.applyServiceStatus(
          model.serviceStatus, connectionState: model.connectionState)
      }
      let inputs = WindowsDesktopRenderInputs(
        revisions: [
          model.displayBox.revision, management.displayBox.revision,
          auxiliary.workspace.displayBox.revision, auxiliary.agentDefaults.displayBox.revision,
          auxiliary.logs.displayBox.revision, auxiliary.settings.displayBox.revision,
          auxiliary.connections.displayBox.revision, appUpdateRevision,
        ],
        page: selectedPage,
        feedback: model.feedback.current,
        chatState: chat.state, chatURL: chat.currentURL, chatError: chat.errorDetail,
        canGoBack: chat.canGoBack, canGoForward: chat.canGoForward,
        desktopState: desktopUI.state, desktopError: desktopUI.errorDetail,
        desktopReady: desktopUI.isReady, desktopLoadStalled: desktopUI.loadStalled
      )
      guard inputs != lastWindowsDesktopRenderInputs else { return }
      lastWindowsDesktopRenderInputs = inputs
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
        browserURL: chat.currentURL,
        browserStatus: browserStatus(for: chat),
        browserCanGoBack: chat.canGoBack,
        browserCanGoForward: chat.canGoForward,
        feedback: model.feedback.current,
        appUpdate: appUpdateState,
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
        return chat.currentURL
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
      let chatURL = WindowsUIThread.shared.chatWebView()?.currentURL ?? WindowsChatWebView.chatURL
      "open".withCString(encodedAs: UTF16.self) { operation in
        chatURL.withCString(encodedAs: UTF16.self) { url in
          _ = ShellExecuteW(
            WindowsMainWindow.currentWindow(), operation, url, nil, nil, SW_SHOWNORMAL)
        }
      }
    }
  }
#endif
