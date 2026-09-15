import BridgeDomain
import BridgeServiceCore
import XCTest

final class CodexSubmissionRoutingTests: XCTestCase {
  func testExplicitCodexSubmissionUsesLegacyCodexPath() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript
    )

    let receipt = try await application.serviceSubmitAgentTask(
      projectID: fixture.project.id.rawValue,
      providerID: serviceCodexProviderID,
      installationID: nil,
      model: nil,
      prompt: "Submit through the explicit Codex provider route.",
      clientRequestID: "explicit-codex-route",
      deadline: ContinuousClock.now.advanced(by: .seconds(10))
    )

    let taskRecord = try await fixture.tasks.task(id: TaskID(rawValue: receipt.taskID))
    let task = try XCTUnwrap(taskRecord)
    XCTAssertEqual(task.providerID, serviceCodexProviderID)
    XCTAssertNil(task.installationID)
    XCTAssertEqual(task.selectionMode, .legacyCodex)
  }
}
