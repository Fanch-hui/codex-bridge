import BridgeMCP
import BridgeServiceAppCore
import XCTest

final class TaskRetrySubmissionTests: XCTestCase {
  func testRetryDropsTheProviderDefaultEffortSentinel() {
    XCTAssertNil(TaskRetrySubmission.effort(for: task(effort: "provider-default")))
    XCTAssertNil(TaskRetrySubmission.effort(for: task(effort: nil)))
    XCTAssertNil(TaskRetrySubmission.effort(for: task(effort: "   ")))
    XCTAssertEqual(TaskRetrySubmission.effort(for: task(effort: " high ")), "high")
  }

  func testRetryKeepsTheModelSentinelOutOfTheOverride() {
    let sentinel = task(effort: nil)
    XCTAssertFalse(TaskRetrySubmission.modelOverride(for: sentinel))
    XCTAssertTrue(TaskRetrySubmission.modelOverride(for: task(effort: nil, model: "gpt-5")))
  }

  private func task(
    effort: String?,
    model: String? = "provider-default"
  ) -> MCPServiceTaskSnapshot {
    MCPServiceTaskSnapshot(
      taskID: "task-retry",
      projectID: "project-1",
      status: "failed",
      providerID: "opencode",
      executionModel: model,
      executionEffort: effort,
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: "2026-09-22T00:00:00Z"
    )
  }
}
