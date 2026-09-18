#if os(Windows)
  import BridgeDesktopUI

  extension WindowsDesktopUIStateBuilder {
    static func workbenchPage(
      _ display: WindowsWorkbenchDisplay,
      management: WindowsManagementDisplay,
      browserAvailable: Bool,
      browserURL: String? = nil,
      browserStatus: String? = nil,
      browserCanGoBack: Bool = false,
      browserCanGoForward: Bool = false,
      modelRefreshInProgress: Bool = false,
      canRefreshModels: Bool = true
    ) -> BridgeDesktopWorkbenchState {
      let projects = management.project.projectItems.map {
        choice($0.projectID, $0.name, detail: $0.detail)
      }
      let permissions = [
        choice("read-only", "只读"),
        choice("workspace-write", "工作区可写"),
      ]
      let (projectStatus, projectStatusTone) = projectStatus(for: display)
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
        history: display.history,
        approvals: display.approvalItems,
        steerModes: steerModes(for: display),
        browser: browserSlot(
          for: display,
          available: browserAvailable,
          url: browserURL,
          status: browserStatus,
          canGoBack: browserCanGoBack,
          canGoForward: browserCanGoForward
        ),
        projectStatus: projectStatus,
        projectStatusTone: projectStatusTone,
        engineStatus: engineStatus(for: display),
        modelCount: display.availableModelCount,
        canRefreshModels: canRefreshModels,
        isRefreshingModels: modelRefreshInProgress,
        modelError: display.modelError,
        commandReceipt: display.commandReceipt
      )
    }

    private static func projectStatus(
      for display: WindowsWorkbenchDisplay
    ) -> (String, String) {
      if let detail = display.selectedTaskDetail {
        if detail.status == "运行中" || detail.status == "正在启动" {
          return ("运行中", "running")
        }
        return (detail.status, tone(for: detail.status))
      }
      if display.runningTaskCount > 0 {
        return ("运行中", "running")
      }
      return ("就绪", "success")
    }

    private static func tone(for status: String) -> String {
      switch status {
      case "运行中", "正在启动": "running"
      case "已完成": "success"
      case "失败": "error"
      case "等待回答", "等待本机批准", "等待 Codex 审批": "warning"
      default: "neutral"
      }
    }

    private static func engineStatus(for display: WindowsWorkbenchDisplay) -> String {
      if display.connectionState != .connected {
        return "等待连接本机 Service"
      }
      if let detail = display.selectedTaskDetail, let step = detail.currentStep, !step.isEmpty {
        return "\(detail.provider) \(step)"
      }
      if display.selectedTaskDetail?.status == "等待回答" {
        return "等待你的回答"
      }
      if let defaultModel = display.defaultModel, !defaultModel.isEmpty {
        return "已连接本机 Codex 引擎 · 默认模型：\(defaultModel)"
      }
      if display.availableModelCount > 0 {
        return "已连接本机 Codex 引擎 (\(display.availableModelCount) 个可用模型)"
      }
      if let error = display.modelError {
        return "Codex 引擎未就绪：\(error)"
      }
      return "已连接本机 Codex 引擎"
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
      url: String?,
      status: String?,
      canGoBack: Bool,
      canGoForward: Bool
    ) -> BridgeDesktopBrowserSlot {
      let enabled = available && display.browserEnabled
      return BridgeDesktopBrowserSlot(
        visible: true,
        enabled: enabled,
        url: url,
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
