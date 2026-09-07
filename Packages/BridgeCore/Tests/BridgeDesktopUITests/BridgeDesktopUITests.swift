import BridgeDesktopUI
import XCTest

final class BridgeDesktopUITests: XCTestCase {
  func testResourcesArePackagedAndReadable() throws {
    XCTAssertNotNil(BridgeDesktopUI.indexURL())
    for resource in BridgeDesktopUIResource.allCases {
      XCTAssertNotNil(BridgeDesktopUIResources.url(for: resource))
      XCTAssertFalse(try BridgeDesktopUIResources.read(resource).isEmpty)
    }

    XCTAssertTrue(try BridgeDesktopUIResources.read(.indexHTML).contains("Codex Bridge"))
    let index = try BridgeDesktopUIResources.read(.indexHTML)
    XCTAssertTrue(index.contains("chat-browser-slot"))
    XCTAssertTrue(index.contains("host-context.js"))
    XCTAssertFalse(index.contains("placeholder-page"))
    XCTAssertTrue(
      try BridgeDesktopUIResources.read(.hostContextJS).contains("platform === \"windows\"")
    )
    let script = try BridgeDesktopUIResources.read(.appJS)
    XCTAssertTrue(script.contains(#"emit("ready")"#))
    XCTAssertTrue(script.contains("window.chrome.webview.addEventListener"))
    XCTAssertTrue(script.contains("toggle-sidebar"))
    XCTAssertTrue(script.contains("measureBrowserViewport"))
    XCTAssertTrue(script.contains("root.dataset.platform"))
    XCTAssertTrue(index.contains("feedback-layer"))
    XCTAssertTrue(index.contains("windows-theme.css"))
    XCTAssertTrue(index.contains("windows-components.css"))
    XCTAssertTrue(index.contains("feedback.js"))
    XCTAssertTrue(index.contains("pages-native-permissions.js"))
    let feedbackScript = try BridgeDesktopUIResources.read(.feedbackJS)
    XCTAssertTrue(feedbackScript.contains("dismissFeedback"))
    XCTAssertTrue(feedbackScript.contains("alertdialog"))
    XCTAssertTrue(feedbackScript.contains("aria-label"))
    XCTAssertTrue(feedbackScript.contains("close.focus"))
    XCTAssertTrue(feedbackScript.contains("event.key === \"Escape\""))
    let windowsTheme = try BridgeDesktopUIResources.read(.windowsThemeCSS)
    XCTAssertTrue(windowsTheme.contains("Segoe UI Variable Text"))
    XCTAssertTrue(windowsTheme.contains(":root[data-platform=\"windows\"]"))
    XCTAssertFalse(
      try BridgeDesktopUIResources.read(.stylesCSS).contains("Segoe UI Variable")
    )
    XCTAssertTrue(
      try BridgeDesktopUIResources.read(.windowsComponentsCSS).contains("feedback-dialog")
    )
    XCTAssertFalse(script.contains("https://"))
    XCTAssertTrue(try BridgeDesktopUIResources.read(.pagesJS).contains("updateBrowserViewport"))
    let workbenchScript = try BridgeDesktopUIResources.read(.pagesWorkbenchJS)
    XCTAssertTrue(workbenchScript.contains("resolveApproval"))
    XCTAssertTrue(workbenchScript.contains("oneTimeApprovalButton"))
    XCTAssertTrue(workbenchScript.contains("remediationCard"))
    XCTAssertTrue(workbenchScript.contains("deleteSession"))
    let workbenchControls = try BridgeDesktopUIResources.read(.pagesWorkbenchControlsJS)
    XCTAssertTrue(workbenchControls.contains("resumeTask"))
    XCTAssertTrue(workbenchControls.contains("restartTask"))
    XCTAssertTrue(
      try BridgeDesktopUIResources.read(.pagesWorkbenchConversationJS).contains(
        "conversationDisclosure"))
    XCTAssertTrue(workbenchScript.contains("confirm("))
    XCTAssertTrue(workbenchScript.contains("setWorkbenchPermissionMode"))
    XCTAssertTrue(workbenchScript.contains("等待 ChatGPT 指令"))
    XCTAssertTrue(index.contains("workbench-browser-toolbar"))
    XCTAssertTrue(index.contains("workbench-inspector-header"))
    XCTAssertTrue(index.contains("workbench-inspector-footer"))
    let projectsScript = try BridgeDesktopUIResources.read(.pagesProjectsJS)
    XCTAssertTrue(projectsScript.contains("CodexBridgeDesktopProjectWorkspace"))
    XCTAssertTrue(
      try BridgeDesktopUIResources.read(.pagesProjectEditorsJS).contains("saveProjectBlacklist"))
    let projectCollections = try BridgeDesktopUIResources.read(.pagesProjectCollectionsJS)
    XCTAssertTrue(projectCollections.contains("addSessionRows"))
    XCTAssertTrue(projectCollections.contains("addThreadTranscript"))
    let commonScript = try BridgeDesktopUIResources.read(.pagesCommonJS)
    XCTAssertTrue(commonScript.contains("function markdown"))
    XCTAssertTrue(commonScript.contains("safeWebURL"))
    XCTAssertFalse(commonScript.contains("innerHTML"))
    let connectionsScript = try BridgeDesktopUIResources.read(.pagesConnectionsJS)
    XCTAssertTrue(connectionsScript.contains("copyLocalMCPEndpoint"))
    XCTAssertTrue(connectionsScript.contains("acceptReplacement: true"))
    XCTAssertTrue(connectionsScript.contains("现有客户端地址将立即失效"))
    let connectionsEditor = try BridgeDesktopUIResources.read(.pagesConnectionsEditorJS)
    XCTAssertTrue(connectionsEditor.contains("现有配置将立即失效"))
    XCTAssertTrue(connectionsEditor.contains("CodexBridgeDesktopFormDraft"))
    XCTAssertTrue(connectionsEditor.contains("configureTunnel"))
    XCTAssertTrue(index.contains("pages-connections-editor.js"))
    let settingsScript = try BridgeDesktopUIResources.read(.pagesSettingsJS)
    XCTAssertTrue(settingsScript.contains("settings-stack"))
    XCTAssertTrue(
      try BridgeDesktopUIResources.read(.pagesSettingsInstructionsJS).contains("TextEncoder"))
    XCTAssertTrue(
      try BridgeDesktopUIResources.read(.pagesSettingsModelsJS).contains("chooseEffort"))
    XCTAssertTrue(settingsScript.contains("nativePermissionPolicy"))
    let nativePermissionScript = try BridgeDesktopUIResources.read(.pagesNativePermissionsJS)
    XCTAssertTrue(nativePermissionScript.contains("setAgentNativePermissionMode"))
    XCTAssertTrue(
      try BridgeDesktopUIResources.read(.pagesSettingsNativeJS).contains(
        "addAgentNativePermissionRule"))
    XCTAssertTrue(
      try BridgeDesktopUIResources.read(.pagesSettingsNativeJS).contains(
        "replaceAgentNativePermissionRule"))
    XCTAssertTrue(
      try BridgeDesktopUIResources.read(.pagesSettingsNativeJS).contains(
        "removeAgentNativePermissionRule"))
    XCTAssertTrue(nativePermissionScript.contains("prepareAgentPermissionRemediation"))
    XCTAssertTrue(nativePermissionScript.contains("applyAgentPermissionRemediation"))
    XCTAssertTrue(nativePermissionScript.contains("oneTimeToolAutoApproval"))
  }

  func testStateRoundTripsThroughJSON() throws {
    let overview = BridgeDesktopOverviewState(
      title: "概览",
      subtitle: "状态",
      notices: [],
      metrics: [
        BridgeDesktopMetric(
          id: "running",
          title: "运行中任务",
          value: "2",
          symbol: "bolt.fill",
          subtitle: "当前执行",
          tone: .running,
          destination: .workbench
        )
      ],
      services: [],
      serviceActions: [
        BridgeDesktopActionLink(
          id: "connections",
          title: "管理连接与 Agent →",
          command: .openConnections
        )
      ],
      recentTasks: [],
      lastUpdatedAt: "2026-09-01T23:46:31Z"
    )
    let state = BridgeDesktopUIState(
      hostContext: BridgeDesktopHostContext(platform: .windows),
      selectedNavigation: .overview,
      connectionLabel: "已连接",
      connectionTone: .success,
      isRefreshing: false,
      feedback: BridgeDesktopFeedback(
        id: "feedback-1",
        kind: .toast,
        tone: .success,
        title: "完成",
        message: "设置已保存"
      ),
      overview: overview,
      workbench: BridgeDesktopWorkbenchState(
        header: BridgeDesktopPageHeader(
          title: "工作台",
          subtitle: "任务",
          symbol: "bubble.left.and.text.bubble.right.fill"
        ),
        browser: BridgeDesktopBrowserSlot(
          visible: true,
          enabled: true,
          url: "https://chatgpt.com/c/example"
        ),
        projectStatus: "就绪",
        projectStatusTone: "success",
        engineStatus: "已连接本机 Codex 引擎"
      )
    )
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(BridgeDesktopUIState.self, from: data)
    XCTAssertEqual(decoded, state)
    XCTAssertEqual(decoded.hostContext?.platform, .windows)
    XCTAssertEqual(decoded.feedback?.id, "feedback-1")
    XCTAssertEqual(decoded.workbench?.projectStatus, "就绪")
    XCTAssertEqual(decoded.workbench?.projectStatusTone, "success")
    XCTAssertEqual(decoded.workbench?.engineStatus, "已连接本机 Codex 引擎")
    XCTAssertEqual(decoded.workbench?.browser.url, "https://chatgpt.com/c/example")
  }

  func testLegacyStateWithoutHostContextOrFeedbackStillDecodes() throws {
    let state = BridgeDesktopUIState(
      selectedNavigation: .overview,
      connectionLabel: "已连接",
      connectionTone: .success,
      isRefreshing: false,
      overview: nil
    )
    let data = try JSONEncoder().encode(state)
    let json = try XCTUnwrap(String(data: data, encoding: .utf8))

    XCTAssertFalse(json.contains("hostContext"))
    XCTAssertFalse(json.contains("feedback"))
    let decoded = try JSONDecoder().decode(BridgeDesktopUIState.self, from: data)
    XCTAssertNil(decoded.hostContext)
    XCTAssertNil(decoded.feedback)
  }

  func testCommandEnvelopeDecodes() throws {
    let data = Data(
      #"{"version":1,"requestID":"request-7","command":"updateBrowserViewport","payload":{"viewport":{"x":1,"y":2,"width":640,"height":480,"visible":true}}}"#
        .utf8
    )
    let envelope = try JSONDecoder().decode(BridgeDesktopCommandEnvelope.self, from: data)
    XCTAssertEqual(envelope.version, BridgeDesktopCommandEnvelope.currentVersion)
    XCTAssertEqual(envelope.requestID, "request-7")
    XCTAssertEqual(envelope.command, .updateBrowserViewport)
    XCTAssertEqual(envelope.payload.viewport?.width, 640)
    XCTAssertTrue(envelope.payload.viewport?.visible == true)
  }

  func testNativePermissionContractsRoundTripThroughJSON() throws {
    let permission = BridgeDesktopNativePermissionState(
      providerID: "antigravity",
      providerName: "Antigravity",
      installationID: "ainst-agy",
      installationName: "AGY CLI",
      installations: [BridgeDesktopChoice(id: "ainst-agy", title: "AGY CLI")],
      toolPermission: "request-review",
      availableModes: [
        BridgeDesktopNativePermissionMode(
          modeID: "request-review",
          displayName: "Request Review"
        )
      ],
      availableActions: ["command"],
      rules: [
        BridgeDesktopNativePermissionRule(
          ruleID: "rule-1",
          effect: "allow",
          action: "command",
          target: "swift test",
          isEditable: true,
          isRedacted: false
        )
      ],
      canEdit: true
    )
    let remediation = BridgeDesktopPermissionRemediationState(
      messageKey: "tool:command-1",
      installationID: "ainst-agy",
      candidateID: "candidate-1",
      action: "command",
      target: "swift test",
      displayRule: "command(swift test)",
      requiresConfirmation: true
    )
    let approval = BridgeDesktopApprovalRow(
      approvalID: "approval-1",
      taskID: "task-1",
      kind: "task_start",
      title: "启动任务",
      summary: "等待本机批准",
      oneTimeToolAutoApprovalAvailable: true
    )

    XCTAssertEqual(
      try JSONDecoder().decode(
        BridgeDesktopNativePermissionState.self,
        from: JSONEncoder().encode(permission)
      ),
      permission
    )
    XCTAssertEqual(
      try JSONDecoder().decode(
        BridgeDesktopPermissionRemediationState.self,
        from: JSONEncoder().encode(remediation)
      ),
      remediation
    )
    XCTAssertEqual(
      try JSONDecoder().decode(
        BridgeDesktopApprovalRow.self,
        from: JSONEncoder().encode(approval)
      ),
      approval
    )
  }

  func testOneTimeApprovalCommandRequiresExplicitConfirmationPayload() throws {
    let data = Data(
      #"{"version":1,"requestID":"approval-1","command":"resolveApproval","payload":{"approvalID":"approval-1","taskID":"task-1","decision":"allow","oneTimeToolAutoApproval":true,"confirmed":true}}"#
        .utf8
    )
    let envelope = try JSONDecoder().decode(BridgeDesktopCommandEnvelope.self, from: data)

    XCTAssertEqual(envelope.command, .resolveApproval)
    XCTAssertTrue(envelope.payload.oneTimeToolAutoApproval == true)
    XCTAssertTrue(envelope.payload.confirmed == true)
  }

  func testSharedPresentationKeepsProviderPermissionsAligned() {
    XCTAssertEqual(
      BridgeDesktopPresentation.agentPermissionOptions(for: "opencode").map(\.id),
      ["build", "plan"]
    )
    XCTAssertEqual(
      BridgeDesktopPresentation.agentPermissionOptions(for: "antigravity").map(\.id),
      ["workspace-write", "plan"]
    )
    XCTAssertEqual(
      BridgeDesktopPresentation.agentPermissionOptions(for: "deepseek-harness").map(\.id),
      ["workspace-write", "read-only"]
    )
    XCTAssertEqual(BridgeDesktopPresentation.reasoningTitle("extra_high"), "极高")
    XCTAssertEqual(BridgeDesktopPresentation.reasoningTitle("none"), "none")
    XCTAssertEqual(BridgeDesktopPresentation.extendedReasoningTitle("none"), "无")
  }

  func testSettingsPatchPreservesPartialUpdateIntent() {
    let patch = BridgeDesktopSettingsPatch(
      executionModel: "gpt-5.6",
      fastModeEnabled: true
    )

    XCTAssertEqual(patch.executionModel, "gpt-5.6")
    XCTAssertNil(patch.executionEffort)
    XCTAssertNil(patch.accessMode)
    XCTAssertTrue(patch.fastModeEnabled == true)
  }
}
