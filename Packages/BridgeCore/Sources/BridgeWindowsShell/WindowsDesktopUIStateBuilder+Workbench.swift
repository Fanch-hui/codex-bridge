#if os(Windows)
  import BridgeDesktopUI

  extension WindowsDesktopUIStateBuilder {
    static func workbenchPage(
      _ display: WindowsWorkbenchDisplay,
      management: WindowsManagementDisplay
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
        selectedProjectID: display.selectedProjectIndex.flatMap {
          management.project.projectItems.indices.contains($0)
            ? management.project.projectItems[$0].projectID : nil
        },
        permissionMode: display.permissionMode,
        permissionOptions: permissions,
        tasks: display.taskItems,
        selectedTaskID: display.selectedTaskID,
        selectedTask: display.selectedTaskDetail,
        approvals: display.approvalItems,
        steerModes: [choice("queued", "当前轮结束后继续")],
        browser: browserSlot(for: display)
      )
    }

    private static func browserSlot(
      for display: WindowsWorkbenchDisplay
    ) -> BridgeDesktopBrowserSlot {
      let available = display.connectionState == .connected
      return BridgeDesktopBrowserSlot(
        visible: true,
        enabled: available,
        status: available ? "由宿主加载真实 ChatGPT 工作区" : "等待本机 Service 与浏览器状态",
        canToggle: false,
        canOpenExternally: true,
        canGoBack: available,
        canGoForward: available,
        canReload: available,
        canLoadEarlierConversation: display.selectedTaskDetail != nil
      )
    }
  }
#endif
