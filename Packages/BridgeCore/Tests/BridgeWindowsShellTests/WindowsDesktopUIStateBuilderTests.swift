#if os(Windows)
  import BridgeDesktopUI
  import XCTest
  @testable import BridgeWindowsShell

  final class WindowsDesktopUIStateBuilderTests: XCTestCase {
    func testBuildUsesLiveCountsAndTaskIdentifiers() {
      let workbench = makeWorkbench(
        taskCount: 7,
        runningTaskCount: 2,
        pendingApprovalCount: 1,
        projectRows: ["Bridge"],
        recentTasks: [
          WindowsRecentTaskPresentation(
            taskID: "task-42",
            title: "修复连接",
            projectName: "Bridge",
            source: "ChatGPT",
            status: "运行中",
            updatedAt: "2026-09-02T12:00:00Z"
          )
        ]
      )
      let management = makeManagement(availableAgentCount: 2, installationCount: 3)

      let state = WindowsDesktopUIStateBuilder.build(
        workbench: workbench,
        management: management
      )

      XCTAssertEqual(state.connectionTone, .success)
      XCTAssertEqual(state.overview?.metrics.first(where: { $0.id == "running-tasks" })?.value, "2")
      XCTAssertEqual(state.overview?.metrics.first(where: { $0.id == "total-tasks" })?.value, "7")
      XCTAssertEqual(state.overview?.recentTasks.map(\.id), ["task-42"])
      XCTAssertEqual(
        state.overview?.services.first(where: { $0.id == "secure-tunnel" })?.value,
        "Windows 不可用"
      )
      XCTAssertEqual(
        state.navigation.first(where: { $0.navigation == .workbench })?.badge,
        1
      )
      XCTAssertEqual(
        state.navigation.first(where: { $0.navigation == .projects })?.badge,
        1
      )
      XCTAssertEqual(state.overview?.notices.map(\.id), ["local-approvals"])
    }

    func testLegacyRowsDoNotCreateSyntheticRecentTaskIdentifiers() {
      let workbench = makeWorkbench(recentTaskRows: ["本机任务 — 已结束"])
      let state = WindowsDesktopUIStateBuilder.build(
        workbench: workbench,
        management: makeManagement()
      )

      XCTAssertTrue(state.overview?.recentTasks.isEmpty == true)
    }

    func testWorkbenchUsesStableProjectAndConversationPagingState() {
      var workbench = makeWorkbench()
      workbench.selectedProjectID = "project-stable"
      workbench.canLoadEarlierConversation = true
      let state = WindowsDesktopUIStateBuilder.build(
        workbench: workbench,
        management: makeManagement()
      )

      XCTAssertEqual(state.workbench?.selectedProjectID, "project-stable")
      XCTAssertEqual(state.workbench?.browser.canLoadEarlierConversation, true)
    }

    func testSharedCommandsRouteToStablePageAndTaskIdentifiers() {
      let page = BridgeDesktopCommandEnvelope(
        requestID: "page-1",
        command: .selectPage,
        payload: .init(navigation: .projects)
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(for: page),
        .selectPage(index: WindowsMainPage.projects.rawValue)
      )

      let task = BridgeDesktopCommandEnvelope(
        requestID: "task-1",
        command: .openTask,
        payload: .init(taskID: "task-42")
      )
      XCTAssertEqual(WindowsDesktopUICommandRouter.command(for: task), .openTask(id: "task-42"))

      let endpoint = BridgeDesktopCommandEnvelope(
        requestID: "endpoint-1",
        command: .copyLocalMCPEndpoint
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(for: endpoint),
        .copyLocalMCPEndpoint
      )

      let unsupportedTunnel = BridgeDesktopCommandEnvelope(
        requestID: "tunnel-1",
        command: .connectTunnel
      )
      XCTAssertNil(WindowsDesktopUICommandRouter.command(for: unsupportedTunnel))

      let browser = BridgeDesktopCommandEnvelope(
        requestID: "browser-1",
        command: .setBrowserEnabled,
        payload: .init(enabled: false)
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(for: browser),
        .setBrowserEnabled(enabled: false)
      )

      let immediateSteer = BridgeDesktopCommandEnvelope(
        requestID: "steer-1",
        command: .steerTask,
        payload: .init(
          taskID: "task-42",
          input: "修正方向",
          mode: "interrupt-current-then-continue"
        )
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(for: immediateSteer),
        .steerTask(
          id: "task-42",
          input: "修正方向",
          mode: "interrupt-current-then-continue"
        )
      )
    }

    private func makeWorkbench(
      taskCount: Int = 0,
      runningTaskCount: Int = 0,
      pendingApprovalCount: Int = 0,
      projectRows: [String] = [],
      recentTaskRows: [String] = [],
      recentTasks: [WindowsRecentTaskPresentation] = []
    ) -> WindowsWorkbenchDisplay {
      WindowsWorkbenchDisplay(
        connectionState: .connected,
        mcpAddress: "http://127.0.0.1:58720/mcp",
        mcpState: "ready",
        taskCount: taskCount,
        runningTaskCount: runningTaskCount,
        pendingApprovalCount: pendingApprovalCount,
        projectRows: projectRows,
        selectedProjectIndex: nil,
        permissionRows: ["只读", "可写"],
        selectedPermissionIndex: 1,
        taskRows: [],
        recentTaskRows: recentTaskRows,
        recentTasks: recentTasks,
        selectedTaskID: nil,
        selectedTaskIndex: nil,
        taskMetadata: "未选择任务",
        conversationText: "",
        interruptEnabled: false,
        stopEnabled: false,
        deleteEnabled: false,
        steerEnabled: false,
        actionText: nil,
        approvalRows: [],
        selectedApprovalIndex: nil,
        approvalDetailText: "",
        approvalAllowDecisions: [],
        approvalAllowEnabled: false,
        approvalDenyEnabled: false,
        approvalStatusText: nil,
        detailText: nil
      )
    }

    private func makeManagement(
      availableAgentCount: Int = 0,
      installationCount: Int = 0
    ) -> WindowsManagementDisplay {
      WindowsManagementDisplay(
        connectionState: .connected,
        availableAgentCount: availableAgentCount,
        project: WindowsProjectManagementDisplay(
          rows: ["Bridge"],
          selectedIndex: 0,
          detailText: "",
          policy: nil,
          registerEnabled: false,
          removeEnabled: false,
          savePolicyEnabled: false,
          statusText: ""
        ),
        agent: WindowsAgentManagementDisplay(
          providerRows: [],
          providerIDs: [],
          selectedProviderIndex: nil,
          providerDetailText: "",
          providerRequiresConfiguration: false,
          installationRows: Array(repeating: "Agent", count: installationCount),
          selectedInstallationIndex: nil,
          installationDetailText: "",
          registerEnabled: false,
          enableEnabled: false,
          disableEnabled: false,
          reprobeEnabled: false,
          acceptReplacementEnabled: false,
          removeEnabled: false,
          statusText: ""
        )
      )
    }
  }
#endif
