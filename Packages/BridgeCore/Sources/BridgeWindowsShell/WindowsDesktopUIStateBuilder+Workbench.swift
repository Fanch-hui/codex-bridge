#if os(Windows)
  import BridgeDesktopUI

  extension WindowsDesktopUIStateBuilder {
    static func workbenchPage(
      _ display: WindowsWorkbenchDisplay,
      management: WindowsManagementDisplay,
      browserAvailable: Bool,
      browserStatus: String? = nil,
      browserCanGoBack: Bool = false,
      browserCanGoForward: Bool = false
    ) -> BridgeDesktopWorkbenchState {
      let projects = management.project.projectItems.map {
        choice($0.projectID, $0.name, detail: $0.detail)
      }
      let permissions = [
        choice("read-only", "只读"),
        choice("workspace-write", "工作区可写"),
      ]
      return BridgeDesktopWorkbenchState(
        header: header(
          "工作台",
          "在 ChatGPT 与本机任务证据之间保持同一工作上下文。",
          "bubble.left.and.text.bubble.right.fill"
        ),
        projects: projects,
        selectedProjectID: display.selectedProjectID,
        permissionMode: display.permissionMode,
        permissionOptions: permissions,
        tasks: display.taskItems,
        selectedTaskID: display.selectedTaskID,
        selectedTask: display.selectedTaskDetail,
        approvals: display.approvalItems,
        steerModes: steerModes(for: display),
        browser: browserSlot(
          for: display,
          available: browserAvailable,
          status: browserStatus,
          canGoBack: browserCanGoBack,
          canGoForward: browserCanGoForward
        )
      )
    }

    private static func steerModes(
      for display: WindowsWorkbenchDisplay
    ) -> [BridgeDesktopChoice] {
      var modes = [choice("queued", "当前轮结束后继续")]
      if display.supportsImmediateSteer {
        modes.append(choice("interrupt-current-then-continue", "中断当前轮并继续"))
      }
      return modes
    }

    private static func browserSlot(
      for display: WindowsWorkbenchDisplay,
      available: Bool,
      status: String?,
      canGoBack: Bool,
      canGoForward: Bool
    ) -> BridgeDesktopBrowserSlot {
      let enabled = available && display.browserEnabled
      return BridgeDesktopBrowserSlot(
        visible: true,
        enabled: enabled,
        status: status ?? (available ? "由宿主加载真实 ChatGPT 工作区" : "内置 WebView2 浏览器不可用"),
        canToggle: available,
        canOpenExternally: true,
        canGoBack: enabled && canGoBack,
        canGoForward: enabled && canGoForward,
        canReload: enabled,
        canLoadEarlierConversation: display.canLoadEarlierConversation
      )
    }
  }
#endif
