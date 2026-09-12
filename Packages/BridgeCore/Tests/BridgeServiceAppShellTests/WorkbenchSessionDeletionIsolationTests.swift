import BridgeMCP
import XCTest

@testable import BridgeServiceAppShell

@MainActor
final class WorkbenchSessionDeletionIsolationTests: XCTestCase {
  func testDeletionScopesByProjectAndProvider() async throws {
    let registration = SessionDeletionRegistration()
    let client = TestBridgeServiceClient()
    await client.setTaskSnapshots([
      task(
        taskID: "agy-task",
        projectID: "project-1",
        providerID: "antigravity",
        sessionID: "shared-session"
      ),
      task(
        taskID: "open-task",
        projectID: "project-1",
        providerID: "opencode",
        sessionID: "shared-session"
      ),
      task(
        taskID: "other-project-task",
        projectID: "project-2",
        providerID: "antigravity",
        sessionID: "shared-session"
      ),
    ])
    await client.setProjects([
      project("project-1", name: "Selected"),
      project("project-2", name: "Other"),
    ])

    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: { client },
      pollInterval: nil,
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )
    await model.startAsync()

    model.deleteSession(
      "shared-session",
      inProject: "project-1",
      providerID: "antigravity"
    )

    try await waitUntil {
      await client.deletedTaskIDsValue() == ["agy-task"]
    }
    await model.shutdownUI()
  }

  private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @MainActor () async -> Bool
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Condition did not become true before the deadline.")
  }

  private func project(_ id: String, name: String) -> MCPProjectSummary {
    MCPProjectSummary(
      projectID: id,
      name: name,
      capabilities: MCPProjectCapabilities(
        read: "allowed",
        write: "requiresLocalApproval",
        network: "denied"
      )
    )
  }

  private func task(
    taskID: String,
    projectID: String,
    providerID: String,
    sessionID: String
  ) -> MCPServiceTaskSnapshot {
    MCPServiceTaskSnapshot(
      taskID: taskID,
      projectID: projectID,
      status: "completed",
      providerID: providerID,
      threadID: providerID == "codex" ? sessionID : nil,
      providerSessionID: providerID == "codex" ? nil : sessionID,
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: "2026-09-12T00:00:00Z"
    )
  }
}

@MainActor
private final class SessionDeletionRegistration: BridgeServiceRegistrationManaging {
  var status: BridgeServiceRegistrationStatus = .enabled

  func register() throws {}

  func unregister() async throws {}

  func openSystemSettings() {}
}
