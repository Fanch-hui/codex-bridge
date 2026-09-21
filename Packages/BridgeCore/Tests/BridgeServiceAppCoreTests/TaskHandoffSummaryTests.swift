import BridgeMCP
import BridgeServiceAppCore
import XCTest

final class TaskHandoffSummaryTests: XCTestCase {
  func testSummaryUsesRecordedWorkAndKeepsChineseTextValid() {
    let task = MCPServiceTaskSnapshot(
      taskID: "tsk-handoff", projectID: "prj-handoff",
      prompt: String(repeating: "处理中文任务", count: 2000), status: "failed", providerID: "codex",
      changedFiles: ["Sources/main.swift"],
      recentEvents: [
        .init(
          sequence: 1, kind: "execution.command_completed", summary: "swift test (exit 1)",
          occurredAt: "2026-09-21")
      ],
      supervisorStatus: "disabled", localApprovalRequired: false,
      resultSummary: "已修改入口，测试尚未通过。", failureCode: "test_failed", updatedAt: "2026-09-21"
    )
    let summary = TaskHandoffSummary.prompt(task: task, history: [task], gitState: "dirty")
    XCTAssertTrue(summary.contains("swift test (exit 1)"))
    XCTAssertTrue(summary.contains("Sources/main.swift"))
    XCTAssertTrue(summary.contains("测试尚未通过"))
    XCTAssertFalse(summary.contains("�"))
    XCTAssertLessThan(summary.utf8.count, 32 * 1024)
  }
}
