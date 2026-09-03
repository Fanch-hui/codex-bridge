import BridgeMCP
import XCTest

@testable import BridgeServiceAppShell

final class WorkbenchThreadTitlePresentationTests: XCTestCase {
  func testShortTitleRemainsUnchanged() {
    XCTAssertEqual(
      WorkbenchThreadTitlePresentation.compact("短会话", maximumCharacters: 28),
      "短会话"
    )
  }

  func testWhitespaceIsCollapsedForSingleLinePresentation() {
    XCTAssertEqual(
      WorkbenchThreadTitlePresentation.compact(
        "第一行\n  第二行\t第三行",
        maximumCharacters: 48
      ),
      "第一行 第二行 第三行"
    )
  }

  func testLongTitleIsCappedWithEllipsis() {
    let compact = WorkbenchThreadTitlePresentation.compact(
      String(repeating: "长", count: 30),
      maximumCharacters: 8
    )

    XCTAssertEqual(compact, "长长长长长长长…")
    XCTAssertEqual(compact.count, 8)
  }

  func testWhitespaceOnlyTitleUsesFallback() {
    XCTAssertEqual(
      WorkbenchThreadTitlePresentation.compact(" \n\t ", maximumCharacters: 28),
      "未命名会话"
    )
  }

  func testUnifiedAgentPickerKeepsTasksAndOnlyAddsOrphanThreads() {
    let codexTask = task(taskID: "codex-task", providerID: "codex", threadID: "thread-1")
    let openCodeTask = task(taskID: "opencode-task", providerID: "opencode")
    let threads = [
      MCPThreadSummary(threadID: "thread-1", title: "Linked", status: "idle"),
      MCPThreadSummary(threadID: "thread-2", title: "Orphan", status: "idle"),
    ]

    XCTAssertEqual(
      WorkbenchAgentTaskPickerContent.orphanThreads(
        tasks: [codexTask, openCodeTask],
        threads: threads
      ).map(\.threadID),
      ["thread-2"]
    )
    XCTAssertEqual(
      WorkbenchAgentTaskPickerContent.itemCount(
        tasks: [codexTask, openCodeTask],
        threads: threads
      ),
      3
    )
  }

  func testExternalTaskCardDoesNotRenderTheFullResultSummary() {
    let task = MCPServiceTaskSnapshot(
      taskID: "opencode-task",
      projectID: "project-1",
      source: nil,
      sourceClientID: nil,
      status: "completed",
      providerID: "opencode",
      installationID: nil,
      executionModel: nil,
      executionEffort: nil,
      threadID: nil,
      turnID: nil,
      providerSessionID: nil,
      providerRunID: nil,
      permissionMode: nil,
      networkAccess: false,
      currentStep: nil,
      changedFiles: [],
      recentEvents: [],
      recentActivity: [],
      recentActivityAvailable: true,
      supervisorStatus: "disabled",
      supervisorSummary: nil,
      localApprovalRequired: false,
      resultSummary: String(repeating: "long report content ", count: 200),
      failureCode: nil,
      updatedAt: "2026-08-26T00:00:00Z"
    )

    let preview = try? XCTUnwrap(WorkbenchTaskTextPresentation.cardTitle(for: task))
    XCTAssertEqual(preview?.count, 240)
    XCTAssertTrue(preview?.hasSuffix("…") == true)
    XCTAssertLessThan(
      WorkbenchTaskTextPresentation.menuTitle(for: task).count,
      task.resultSummary?.count ?? 0
    )
  }

  func testExternalTaskCardBoundsTheCurrentStepPreview() {
    let task = MCPServiceTaskSnapshot(
      taskID: "opencode-task",
      projectID: "project-1",
      source: nil,
      sourceClientID: nil,
      status: "running",
      providerID: "opencode",
      installationID: nil,
      executionModel: nil,
      executionEffort: nil,
      threadID: nil,
      turnID: nil,
      providerSessionID: nil,
      providerRunID: nil,
      permissionMode: nil,
      networkAccess: false,
      currentStep: String(repeating: "step ", count: 100),
      changedFiles: [],
      recentEvents: [],
      recentActivity: [],
      recentActivityAvailable: true,
      supervisorStatus: "disabled",
      supervisorSummary: nil,
      localApprovalRequired: false,
      resultSummary: nil,
      failureCode: nil,
      updatedAt: "2026-08-26T00:00:00Z"
    )

    guard let preview = WorkbenchTaskTextPresentation.cardTitle(for: task) else {
      XCTFail("Expected a bounded current-step preview")
      return
    }
    XCTAssertEqual(preview.count, 240)
    XCTAssertTrue(preview.hasSuffix("…"))
  }

  func testMultiTurnTasksAreConsolidatedIntoSingleSession() {
    let turn1 = MCPServiceTaskSnapshot(
      taskID: "task-1",
      projectID: "proj-1",
      prompt: "这是第一轮提示词",
      status: "completed",
      providerID: "antigravity",
      providerSessionID: "agy-session-123",
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: "2026-08-28T00:00:01Z"
    )
    let turn2 = MCPServiceTaskSnapshot(
      taskID: "task-2",
      projectID: "proj-1",
      prompt: "这是第二轮提示词",
      status: "completed",
      providerID: "antigravity",
      providerSessionID: "agy-session-123",
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: "2026-08-28T00:00:02Z"
    )

    let sessions = WorkbenchAgentTaskPickerContent.sessions(tasks: [turn1, turn2])
    XCTAssertEqual(sessions.count, 1)
    let session = sessions[0]
    XCTAssertEqual(session.sessionID, "agy-session-123")
    XCTAssertEqual(session.providerID, "antigravity")
    XCTAssertEqual(session.turnCount, 2)
    XCTAssertEqual(session.latestTask.taskID, "task-2")
    XCTAssertEqual(session.title, "这是第一轮提示词")

    let titleWithTurns = WorkbenchTaskTextPresentation.sessionMenuTitle(
      title: session.title,
      turnCount: session.turnCount
    )
    XCTAssertEqual(titleWithTurns, "这是第一轮提示词 [2轮]")
  }

  func testGroupedSessionsCategorizesByProvider() {
    let codexTask = MCPServiceTaskSnapshot(
      taskID: "codex-1",
      projectID: "proj-1",
      status: "completed",
      providerID: "codex",
      threadID: "th-1",
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: "2026-08-28T00:00:01Z"
    )
    let agyTask = MCPServiceTaskSnapshot(
      taskID: "agy-1",
      projectID: "proj-1",
      status: "completed",
      providerID: "antigravity",
      providerSessionID: "agy-sess-1",
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: "2026-08-28T00:00:02Z"
    )
    let openCodeTask = MCPServiceTaskSnapshot(
      taskID: "opencode-1",
      projectID: "proj-1",
      status: "completed",
      providerID: "opencode",
      providerSessionID: "oc-sess-1",
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: "2026-08-28T00:00:03Z"
    )

    let groups = WorkbenchAgentTaskPickerContent.groupedSessions(tasks: [codexTask, agyTask, openCodeTask])
    XCTAssertEqual(groups.map(\.providerID), ["codex", "antigravity", "opencode"])
    XCTAssertEqual(groups[0].sessions.count, 1)
    XCTAssertEqual(groups[1].sessions.count, 1)
    XCTAssertEqual(groups[2].sessions.count, 1)
  }

  func testCleanTitleSanitizesToolFailureErrors() {
    let rawError = "Antigravity could not run native tool 'view_file': operation timed out while executing"
    let cleaned = WorkbenchTaskTextPresentation.cleanTitle(rawError)
    XCTAssertEqual(cleaned, "工具 view_file 执行异常")

    let rawDenied = "The user denied this provider invocation request in the desktop application"
    let cleanedDenied = WorkbenchTaskTextPresentation.cleanTitle(rawDenied)
    XCTAssertEqual(cleanedDenied, "用户拒绝执行")
  }

  private func task(
    taskID: String,
    providerID: String,
    threadID: String? = nil
  ) -> MCPServiceTaskSnapshot {
    MCPServiceTaskSnapshot(
      taskID: taskID,
      projectID: "project-1",
      status: "completed",
      providerID: providerID,
      threadID: threadID,
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: "2026-08-28T00:00:00Z"
    )
  }
}
