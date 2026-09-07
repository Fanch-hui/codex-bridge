import BridgeDesktopUI
import BridgeIPC
import BridgeMCP
import Foundation
import XCTest

@testable import BridgeServiceAppShell

@MainActor
final class BridgeDesktopBridgeTests: XCTestCase {
  func testStateBuilderPublishesEveryPageFromLiveModel() async throws {
    let model = BridgeServiceAppModel(
      registration: BridgeDesktopTestServiceRegistration(status: .enabled),
      clientFactory: { TestBridgeServiceClient() },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()

    let state = BridgeDesktopUIStateBuilder.build(from: model)
    XCTAssertNotNil(state.overview)
    XCTAssertNotNil(state.workbench)
    XCTAssertNotNil(state.projects)
    XCTAssertNotNil(state.logs)
    XCTAssertNotNil(state.connections)
    XCTAssertNotNil(state.settings)
    XCTAssertEqual(
      state.projects?.rows.map { $0.projectID } ?? [],
      model.projects.map { $0.projectID }
    )
    XCTAssertEqual(
      state.workbench?.tasks.map { $0.taskID } ?? [],
      model.tasks.map { $0.taskID }
    )
    XCTAssertEqual(state.workbench?.projectStatus, "就绪")
    XCTAssertEqual(state.workbench?.projectStatusTone, "success")
    XCTAssertNotNil(state.workbench?.engineStatus)
    XCTAssertEqual(
      state.connections?.providers.map { $0.providerID } ?? [],
      model.agentProviders.map { $0.providerID }
    )
  }

  func testWorkbenchHistoryIncludesOrphansAndUsesSelectedTranscript() {
    let model = BridgeServiceAppModel(
      registration: BridgeDesktopTestServiceRegistration(status: .enabled),
      clientFactory: { TestBridgeServiceClient() },
      pollInterval: nil
    )
    let linked = MCPThreadSummary(threadID: "linked", title: "已关联", status: "idle")
    let orphan = MCPThreadSummary(threadID: "orphan", title: "历史会话", status: "idle")
    model.selectedProjectID = "project-1"
    model.tasks = [
      MCPServiceTaskSnapshot(
        taskID: "task-1",
        projectID: "project-1",
        status: "completed",
        providerID: "codex",
        threadID: "linked",
        supervisorStatus: "disabled",
        localApprovalRequired: false,
        updatedAt: "2026-09-07T00:00:00Z"
      )
    ]
    model.threads = [linked, orphan]
    model.selectedTaskID = nil
    model.selectedThreadID = orphan.threadID
    model.selectedThread = MCPThreadReadPage(
      thread: orphan,
      detail: .full,
      entries: [MCPThreadEntry(turnID: "turn-1", role: "assistant", text: "已有的完整记录")]
    )

    let state = BridgeDesktopUIStateBuilder.workbench(from: model)
    XCTAssertEqual(state.history.threads.map(\.threadID), ["orphan"])
    XCTAssertEqual(state.history.selectedThreadID, "orphan")
    XCTAssertEqual(state.history.selectedThreadTitle, "历史会话")
    XCTAssertEqual(state.history.conversation.map(\.text), ["已有的完整记录"])
    XCTAssertNil(state.selectedTask)

    model.selectedTaskID = "task-1"
    let taskState = BridgeDesktopUIStateBuilder.workbench(from: model)
    XCTAssertNil(taskState.history.selectedThreadID)
    XCTAssertTrue(taskState.history.conversation.isEmpty)
    XCTAssertEqual(taskState.selectedTask?.taskID, "task-1")
  }

  func testLogCategoryUsesPersistedServiceEventKind() {
    XCTAssertEqual(
      BridgeDesktopLogPresentation.category(for: "execution.command_completed"),
      "command"
    )
    XCTAssertEqual(
      BridgeDesktopLogPresentation.category(for: "execution.file_changed"),
      "file"
    )
    XCTAssertEqual(
      BridgeDesktopLogPresentation.category(for: "task.failed"),
      "other"
    )
  }

  func testBrowserViewportCommandAcceptsFiniteLocalGeometryOnly() {
    let defaults = UserDefaults(suiteName: "BridgeDesktopBridgeTests.viewport")!
    defaults.set(true, forKey: "chatBrowserEnabled")
    let model = BridgeServiceAppModel(
      registration: BridgeDesktopTestServiceRegistration(status: .enabled),
      clientFactory: { TestBridgeServiceClient() },
      pollInterval: nil,
      userDefaults: defaults
    )
    model.selection = BridgeServiceNavigation.workbench
    let viewport = BridgeDesktopBrowserViewport(
      x: 10,
      y: 20,
      width: 300,
      height: 400,
      visible: true
    )
    BridgeDesktopCommandRouter.handle(
      BridgeDesktopCommandEnvelope(
        requestID: "viewport",
        command: .updateBrowserViewport,
        payload: BridgeDesktopCommandPayload(viewport: viewport)
      ),
      model: model
    )
    XCTAssertEqual(model.chatBrowserViewport, viewport)

    let invalid = BridgeDesktopBrowserViewport(
      x: -.infinity,
      y: 0,
      width: 300,
      height: 400,
      visible: true
    )
    BridgeDesktopCommandRouter.handle(
      BridgeDesktopCommandEnvelope(
        requestID: "invalid",
        command: .updateBrowserViewport,
        payload: BridgeDesktopCommandPayload(viewport: invalid)
      ),
      model: model
    )
    XCTAssertNil(model.chatBrowserViewport)
    defaults.removePersistentDomain(forName: "BridgeDesktopBridgeTests.viewport")
  }

  func testSharedSettingsExposeAGYPolicyAndRequireConfirmationForDangerousMode()
    async throws
  {
    let client = TestBridgeServiceClient()
    let installation = IPCAgentInstallationSummary(
      installationID: "ainst-agy",
      providerID: "antigravity",
      displayName: "AGY CLI",
      executablePath: "/tmp/agy",
      version: "1.1.22",
      protocolRevision: "stream-json-v1",
      adapterRevision: 1,
      trustProfile: "user_trusted",
      securityProfileID: "desktop-shared",
      isEnabled: true,
      availability: "available",
      effectiveCapabilities: ["workspace.read", "workspace.write"],
      lastProbedAt: "2026-09-03T00:00:00Z",
      updatedAt: "2026-09-03T00:00:00Z"
    )
    let policy = IPCAgentNativePermissionPolicyResponse(
      providerID: "antigravity",
      installationID: installation.installationID,
      toolPermission: "request-review",
      availableModes: [
        IPCAgentNativePermissionModeSummary(
          modeID: "request-review",
          displayName: "Request Review",
          requiresConfirmation: false
        ),
        IPCAgentNativePermissionModeSummary(
          modeID: "always-proceed",
          displayName: "Always Proceed",
          requiresConfirmation: true
        ),
      ],
      availableActions: ["command"],
      rules: [],
      revision: "revision-1",
      warnings: []
    )
    await client.configureAgentInstallations([installation])
    await client.configureNativePermissionPolicy(policy)
    let model = BridgeServiceAppModel(
      registration: BridgeDesktopTestServiceRegistration(status: .enabled),
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()
    await model.loadNativePermissionPolicy(installationID: installation.installationID)

    let state = BridgeDesktopUIStateBuilder.build(from: model)
    XCTAssertEqual(
      state.settings?.nativePermissionPolicy?.installationID, installation.installationID)
    XCTAssertEqual(state.settings?.nativePermissionPolicy?.toolPermission, "request-review")
    XCTAssertEqual(state.settings?.nativePermissionPolicy?.installations.count, 1)

    BridgeDesktopCommandRouter.handle(
      BridgeDesktopCommandEnvelope(
        requestID: "unsafe-mode-unconfirmed",
        command: .setAgentNativePermissionMode,
        payload: BridgeDesktopCommandPayload(
          installationID: installation.installationID,
          toolPermission: "always-proceed"
        )
      ),
      model: model
    )
    await Task.yield()
    let unconfirmedMutations = await client.nativePermissionMutationValues()
    XCTAssertTrue(unconfirmedMutations.isEmpty)

    BridgeDesktopCommandRouter.handle(
      BridgeDesktopCommandEnvelope(
        requestID: "unsafe-mode-confirmed",
        command: .setAgentNativePermissionMode,
        payload: BridgeDesktopCommandPayload(
          installationID: installation.installationID,
          toolPermission: "always-proceed",
          confirmed: true
        )
      ),
      model: model
    )
    try await waitForDesktopCondition {
      await client.nativePermissionMutationValues().count == 1
    }
  }
}

private func waitForDesktopCondition(
  _ predicate: @escaping @Sendable () async -> Bool
) async throws {
  for _ in 0..<100 {
    if await predicate() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  XCTFail("Timed out waiting for desktop bridge state")
}

@MainActor
private final class BridgeDesktopTestServiceRegistration: BridgeServiceRegistrationManaging {
  var status: BridgeServiceRegistrationStatus

  init(status: BridgeServiceRegistrationStatus) {
    self.status = status
  }

  func register() throws {
    status = .enabled
  }

  func unregister() async throws {
    status = .notRegistered
  }

  func openSystemSettings() {}
}
