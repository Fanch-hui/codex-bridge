import BridgeDomain
import BridgeMCP
import BridgeServiceApplication
import BridgeServiceCore
import XCTest

final class ContinuationSnapshotTests: XCTestCase {
  func testContinuationHasSessionIdentityBeforeProviderStarts() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture, catalogScript: serviceModelCatalogScript)
    for provider in ["codex", "opencode", "antigravity", "deepseek-harness"] {
      let creation = try await fixture.tasks.submit(
        ServiceTaskRequest(
          projectID: fixture.project.id, source: .mcpClient, sourceClientID: "chatgpt",
          prompt: "Continue the conversation.", requestedThreadID: "existing-session",
          providerID: provider, installationID: "ainst-test", selectionMode: .explicit,
          executionModel: serviceDefaultProviderExecutionModel,
          executionEffort: serviceDefaultProviderExecutionEffort, permissionMode: .readOnly
        ), taskID: TaskID(rawValue: "task-\(provider)")
      )
      let snapshot = try await application.serviceTask(
        taskID: creation.task.id.rawValue, recentEventLimit: 6,
        deadline: ContinuousClock.now.advanced(by: .seconds(3))
      )
      XCTAssertEqual(
        provider == "codex" ? snapshot.threadID : snapshot.providerSessionID, "existing-session")
      XCTAssertNil(snapshot.providerRunID)
      XCTAssertNil(snapshot.turnID)
    }
  }
}
