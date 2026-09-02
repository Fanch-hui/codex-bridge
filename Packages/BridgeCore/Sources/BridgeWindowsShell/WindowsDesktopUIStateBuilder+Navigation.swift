#if os(Windows)
  import BridgeDesktopUI

  extension WindowsDesktopUIStateBuilder {
    static func navigation(
      workbench: WindowsWorkbenchDisplay,
      management: WindowsManagementDisplay
    ) -> [BridgeDesktopNavigationItem] {
      BridgeDesktopNavigation.allCases.map { item in
        BridgeDesktopNavigationItem(
          navigation: item,
          badge: navigationBadge(for: item, workbench: workbench, management: management)
        )
      }
    }

    static func notices(
      workbench: WindowsWorkbenchDisplay
    ) -> [BridgeDesktopNotice] {
      var result: [BridgeDesktopNotice] = []
      if workbench.connectionState == .unavailable {
        result.append(
          BridgeDesktopNotice(
            id: "service-unavailable",
            title: "后台 Service 不可用",
            message: workbench.detailText ?? "无法读取本机 Service 状态。",
            symbol: "circle.dashed",
            tone: .error,
            destination: .connections
          )
        )
      }
      if workbench.pendingApprovalCount > 0 {
        result.append(
          BridgeDesktopNotice(
            id: "local-approvals",
            title: "待处理本机审批",
            message: "当前有 \(workbench.pendingApprovalCount) 个远程任务或执行器操作等待你本机确认或拒绝。",
            symbol: "shield.lefthalf.filled",
            tone: .warning,
            destination: .workbench
          )
        )
      }
      return result
    }

    private static func navigationBadge(
      for navigation: BridgeDesktopNavigation,
      workbench: WindowsWorkbenchDisplay,
      management: WindowsManagementDisplay
    ) -> Int? {
      switch navigation {
      case .workbench:
        if workbench.pendingApprovalCount > 0 { return workbench.pendingApprovalCount }
        return workbench.runningTaskCount > 0 ? workbench.runningTaskCount : nil
      case .projects:
        let count = management.project.projectItems.count
        return count > 0 ? count : nil
      default:
        return nil
      }
    }
  }
#endif
