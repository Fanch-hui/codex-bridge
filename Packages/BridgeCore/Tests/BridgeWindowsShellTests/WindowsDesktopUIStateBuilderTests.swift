#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import XCTest
  @testable import BridgeWindowsShell

  final class WindowsDesktopUIStateBuilderTests: XCTestCase {
    func testConnectionEndpointProjectionDropsCredentialsAndPath() {
      XCTAssertEqual(
        WindowsConnectionModel.safeLocalMCPDescription(
          from: "http://127.0.0.1:58720/internal?token=hidden"
        ),
        "http://127.0.0.1:58720/mcp"
      )
      XCTAssertNil(WindowsConnectionModel.safeLocalMCPDescription(from: "not a URL"))
    }

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

      XCTAssertEqual(state.hostContext?.platform, .windows)
      XCTAssertEqual(state.connectionTone, .success)
      XCTAssertEqual(state.overview?.metrics.first(where: { $0.id == "running-tasks" })?.value, "2")
      XCTAssertEqual(state.overview?.metrics.first(where: { $0.id == "total-tasks" })?.value, "7")
      XCTAssertEqual(state.overview?.recentTasks.map(\.id), ["task-42"])
      XCTAssertEqual(
        state.overview?.services.first(where: { $0.id == "secure-tunnel" })?.value,
        "未配置"
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

    func testConnectionsExposeCodexModelRefreshState() {
      var settings = makeSettings()
      settings.modelOptions = [
        BridgeDesktopModelOption(modelID: "gpt-5.6", displayName: "GPT-5.6")
      ]
      settings.isRefreshingModels = true
      let state = WindowsDesktopUIStateBuilder.build(
        workbench: makeWorkbench(),
        management: makeManagement(),
        connections: makeConnections(tunnel: nil),
        settings: settings
      )

      XCTAssertEqual(state.connections?.codex?.modelCount, 1)
      XCTAssertTrue(state.connections?.codex?.isRefreshing == true)
      XCTAssertFalse(state.connections?.codex?.canRefresh == true)
    }

    func testConnectionsExposeConfiguredCodexExecutable() {
      var connections = makeConnections(tunnel: nil)
      connections.codexExecutablePath = "C:\\Tools\\codex\\codex.exe"
      connections.codexResolvedExecutablePath = "C:\\Tools\\codex\\codex.exe"
      let state = WindowsDesktopUIStateBuilder.build(
        workbench: makeWorkbench(),
        management: makeManagement(),
        connections: connections,
        settings: makeSettings()
      )

      XCTAssertEqual(state.connections?.codex?.executablePath, "C:\\Tools\\codex\\codex.exe")
      XCTAssertEqual(
        state.connections?.codex?.resolvedExecutablePath, "C:\\Tools\\codex\\codex.exe")
      XCTAssertTrue(state.connections?.codex?.canEditExecutable == true)
    }

    func testConnectionsReflectCodexExecutableChangesInTheCacheKey() {
      var connections = makeConnections(tunnel: nil)
      let initial = WindowsDesktopConnectionsCacheKey(
        workbench: makeWorkbench(),
        management: makeManagement(),
        connections: connections,
        settings: makeSettings()
      )
      connections.codexExecutablePath = "C:\\Tools\\codex\\codex.exe"
      let updated = WindowsDesktopConnectionsCacheKey(
        workbench: makeWorkbench(),
        management: makeManagement(),
        connections: connections,
        settings: makeSettings()
      )

      XCTAssertNotEqual(initial, updated)
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
      XCTAssertEqual(state.workbench?.projectStatus, "就绪")
      XCTAssertEqual(state.workbench?.projectStatusTone, "success")
      XCTAssertEqual(state.workbench?.engineStatus, "已连接本机 Codex 引擎")
    }

    func testWorkbenchShowsProjectQueryFailureWithoutReplacingProjectContext() {
      var workbench = makeWorkbench(projectRows: ["Bridge"])
      workbench.selectedProjectID = "project-bridge"
      workbench.projectLoadError = "项目查询失败：后台忙"
      let management = makeManagement(
        projectItems: [
          BridgeDesktopProjectRow(
            projectID: "project-bridge",
            name: "Bridge",
            readPermission: "allowed",
            writePermission: "denied",
            networkPermission: "denied",
            selected: true
          )
        ]
      )

      let state = WindowsDesktopUIStateBuilder.build(
        workbench: workbench,
        management: management
      )

      XCTAssertEqual(state.workbench?.projects.map(\.title), ["Bridge"])
      XCTAssertEqual(state.workbench?.selectedProjectID, "project-bridge")
      XCTAssertEqual(state.workbench?.projectStatus, "项目查询失败")
      XCTAssertEqual(state.workbench?.projectStatusTone, "error")
    }

    func testWorkbenchPublishesCurrentBrowserURL() {
      let state = WindowsDesktopUIStateBuilder.build(
        workbench: makeWorkbench(),
        management: makeManagement(),
        browserURL: "https://chatgpt.com/c/example"
      )

      XCTAssertEqual(state.workbench?.browser.url, "https://chatgpt.com/c/example")
    }

    func testDesktopCommandsStayTypedOnTheWindowQueue() {
      let envelopes = [
        BridgeDesktopCommandEnvelope(requestID: "refresh-1", command: .refresh),
        BridgeDesktopCommandEnvelope(
          requestID: "page-1", command: .selectPage, payload: .init(navigation: .projects)),
        BridgeDesktopCommandEnvelope(
          requestID: "task-1", command: .openTask, payload: .init(taskID: "task-42")),
        BridgeDesktopCommandEnvelope(
          requestID: "settings-1", command: .setExecutionModel,
          payload: .init(modelID: "gpt-5.6")),
        BridgeDesktopCommandEnvelope(
          requestID: "tunnel-1", command: .configureTunnel,
          payload: .init(tunnelID: "tunnel-9", runtimeKey: "runtime-key")),
      ]
      for envelope in envelopes {
        XCTAssertEqual(
          WindowsDesktopUICommandRouter.command(for: envelope),
          .desktopCommand(envelope)
        )
      }
    }

    func testWindowsUsesSharedAgentPermissions() {
      XCTAssertEqual(
        WindowsAgentDefaultsModel.permissionValues(for: "antigravity"),
        ["workspace-write", "plan"]
      )
      XCTAssertEqual(
        WindowsAgentDefaultsModel.permissionValues(for: "opencode"),
        ["build", "plan"]
      )
    }

    func testAgentModelProjectionPreservesReasoningCapabilityState() {
      let model = IPCAgentModelSummary(
        modelID: "provider/model",
        displayName: "Model",
        supportedReasoningEfforts: [],
        reasoningCapabilitiesAvailable: false,
        isDefaultModel: true
      )

      let option = WindowsDesktopAgentPresentation.model(model)

      XCTAssertEqual(option.reasoningCapabilitiesAvailable, false)
      XCTAssertEqual(option.isDefaultModel, true)
    }

  }
#endif
