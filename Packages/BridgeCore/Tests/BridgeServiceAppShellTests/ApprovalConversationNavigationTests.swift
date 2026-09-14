import BridgeIPC
import BridgeMCP
import XCTest

@testable import BridgeServiceAppShell

@MainActor
final class ApprovalConversationNavigationTests: XCTestCase {
  func testApprovalOpensNextTurnAndRetainsPreviousTurn() async throws {
    let client = TestBridgeServiceClient()
    let previous = MCPServiceTaskSnapshot(
      taskID: "previous", projectID: "project-1", status: "completed",
      threadID: "thread-1", supervisorStatus: "stopped", localApprovalRequired: false,
      updatedAt: "2026-08-16T00:00:00Z"
    )
    let next = MCPServiceTaskSnapshot(
      taskID: "task-1", projectID: "project-1", status: "awaiting_local_approval",
      threadID: "thread-1", supervisorStatus: "starting", localApprovalRequired: true,
      updatedAt: "2026-08-17T00:00:00Z"
    )
    await client.setTaskSnapshots([next, previous])
    let model = BridgeServiceAppModel(
      registration: ApprovalTestRegistration(), clientFactory: { client },
      pollInterval: nil, connectionRetryDelay: .milliseconds(1), maximumConnectionAttempts: 1
    )
    await model.startAsync()
    model.openTask("previous")
    let approval = try XCTUnwrap(model.approvals.first)
    model.resolveApproval(approval, decision: "allow")
    for _ in 0..<100 where model.isResolvingApproval(approval) {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(model.selectedTaskID, "task-1")
    XCTAssertEqual(model.conversation?.taskID, "task-1")
    XCTAssertEqual(model.conversation?.priorTaskIDs, ["previous"])
    XCTAssertEqual(model.selection, .workbench)
    model.closeConversation()
  }
}

@MainActor
private final class ApprovalTestRegistration: BridgeServiceRegistrationManaging {
  var status: BridgeServiceRegistrationStatus { .enabled }
  func register() throws {}
  func unregister() async throws {}
  func openSystemSettings() {}
}
