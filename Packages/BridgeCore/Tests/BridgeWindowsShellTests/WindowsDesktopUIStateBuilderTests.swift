#if os(Windows)
  import BridgeDesktopUI
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

    func testWorkbenchPublishesCurrentBrowserURL() {
      let state = WindowsDesktopUIStateBuilder.build(
        workbench: makeWorkbench(),
        management: makeManagement(),
        browserURL: "https://chatgpt.com/c/example"
      )

      XCTAssertEqual(state.workbench?.browser.url, "https://chatgpt.com/c/example")
    }

    func testSharedCommandsRouteToStablePageAndTaskIdentifiers() {
      let refresh = BridgeDesktopCommandEnvelope(
        requestID: "refresh-1",
        command: .refresh
      )
      XCTAssertEqual(WindowsDesktopUICommandRouter.command(for: refresh), .refreshAll)

      let refreshModels = BridgeDesktopCommandEnvelope(
        requestID: "refresh-models-1",
        command: .refreshModels
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(for: refreshModels),
        .refreshModels
      )

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

      let resume = BridgeDesktopCommandEnvelope(
        requestID: "resume-1",
        command: .resumeTask,
        payload: .init(taskID: "task-42", input: "继续完成")
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(for: resume),
        .resumeTask(id: "task-42", input: "继续完成")
      )

      let restart = BridgeDesktopCommandEnvelope(
        requestID: "restart-1",
        command: .restartTask,
        payload: .init(taskID: "task-42")
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(for: restart),
        .restartTask(id: "task-42")
      )

      let deleteSession = BridgeDesktopCommandEnvelope(
        requestID: "delete-session-1",
        command: .deleteSession,
        payload: .init(taskID: "task-42", sessionID: "session-9")
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(for: deleteSession),
        .deleteSession(taskID: "task-42")
      )

      let providerDefault = BridgeDesktopCommandEnvelope(
        requestID: "agent-default-1",
        command: .saveAgentDefault,
        payload: .init(
          providerID: "opencode",
          installationID: "installation-1",
          modelID: nil,
          permissionMode: "build"
        )
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(for: providerDefault),
        .saveAgentDefault(
          providerID: "opencode",
          installationID: "installation-1",
          modelID: nil,
          permissionMode: "build",
          effort: nil
        )
      )
      let providerPermissionOnly = BridgeDesktopCommandEnvelope(
        requestID: "agent-permission-only-1",
        command: .saveAgentDefault,
        payload: .init(
          providerID: "antigravity",
          permissionMode: "workspace-write"
        )
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(for: providerPermissionOnly),
        .saveAgentDefault(
          providerID: "antigravity",
          installationID: nil,
          modelID: nil,
          permissionMode: "workspace-write",
          effort: nil
        )
      )

      let agentConnection = BridgeDesktopCommandEnvelope(
        requestID: "agent-connect-1",
        command: .connectAgent,
        payload: .init(
          providerID: "deepseek-harness",
          baseURL: "https://api.example.test",
          apiKey: "secret"
        )
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(for: agentConnection),
        .connectAgentFromDesktop(
          providerID: "deepseek-harness",
          baseURL: "https://api.example.test",
          apiKey: "secret",
          alwaysProceedConfirmed: false
        )
      )

      let executionModel = BridgeDesktopCommandEnvelope(
        requestID: "settings-1",
        command: .setExecutionModel,
        payload: .init(modelID: "gpt-5.6")
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(for: executionModel),
        .patchSettings(BridgeDesktopSettingsPatch(executionModel: "gpt-5.6"))
      )

      let fastMode = BridgeDesktopCommandEnvelope(
        requestID: "settings-2",
        command: .setFastMode,
        payload: .init(fastModeEnabled: true)
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(for: fastMode),
        .patchSettings(BridgeDesktopSettingsPatch(fastModeEnabled: true))
      )

      let dismiss = BridgeDesktopCommandEnvelope(
        requestID: "feedback-1",
        command: .dismissFeedback,
        payload: .init(feedbackID: "windows-feedback-7")
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(for: dismiss),
        .dismissFeedback(id: "windows-feedback-7")
      )
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

    func testTunnelCommandsRouteToServiceBackedWindowCommands() {
      let connect = BridgeDesktopCommandEnvelope(
        requestID: "tunnel-1",
        command: .connectTunnel
      )
      XCTAssertEqual(WindowsDesktopUICommandRouter.command(for: connect), .connectTunnel)

      let disconnect = BridgeDesktopCommandEnvelope(
        requestID: "tunnel-2",
        command: .disconnectTunnel
      )
      XCTAssertEqual(WindowsDesktopUICommandRouter.command(for: disconnect), .disconnectTunnel)

      let clear = BridgeDesktopCommandEnvelope(
        requestID: "tunnel-3",
        command: .clearTunnel
      )
      XCTAssertEqual(WindowsDesktopUICommandRouter.command(for: clear), .clearTunnel)

      let configure = BridgeDesktopCommandEnvelope(
        requestID: "tunnel-4",
        command: .configureTunnel,
        payload: .init(tunnelID: " tunnel-9 ", runtimeKey: "runtime-key")
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(for: configure),
        .configureTunnel(tunnelID: "tunnel-9", runtimeKey: "runtime-key")
      )
    }

    func testConfigureTunnelWithoutUsablePayloadIsDropped() {
      for payload in [
        BridgeDesktopCommandPayload(),
        BridgeDesktopCommandPayload(tunnelID: "tunnel-9"),
        BridgeDesktopCommandPayload(tunnelID: "tunnel-9", runtimeKey: "   "),
        BridgeDesktopCommandPayload(runtimeKey: "runtime-key"),
      ] {
        let envelope = BridgeDesktopCommandEnvelope(
          requestID: "tunnel-5",
          command: .configureTunnel,
          payload: payload
        )
        XCTAssertNil(WindowsDesktopUICommandRouter.command(for: envelope))
      }
    }

  }
#endif
