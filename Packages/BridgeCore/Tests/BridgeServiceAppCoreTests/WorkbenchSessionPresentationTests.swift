import BridgeMCP
import BridgeServiceAppCore
import XCTest

final class WorkbenchSessionPresentationTests: XCTestCase {
  func testSessionsGroupOnlyMatchingProjectProviderAndSession() throws {
    let first = task(
      taskID: "task-1",
      projectID: "project-1",
      providerID: "antigravity",
      sessionID: "session-1",
      prompt: "检查 Windows 对齐",
      updatedAt: "2026-09-04T00:00:01Z"
    )
    let second = task(
      taskID: "task-2",
      projectID: "project-1",
      providerID: "antigravity",
      sessionID: "session-1",
      prompt: "继续修复",
      updatedAt: "2026-09-04T00:00:02Z"
    )
    let otherProvider = task(
      taskID: "task-3",
      projectID: "project-1",
      providerID: "opencode",
      sessionID: "session-1",
      updatedAt: "2026-09-04T00:00:03Z"
    )
    let otherProject = task(
      taskID: "task-4",
      projectID: "project-2",
      providerID: "antigravity",
      sessionID: "session-1",
      updatedAt: "2026-09-04T00:00:04Z"
    )

    let sessions = WorkbenchSessionCatalog.sessions(
      tasks: [second, otherProvider, first, otherProject]
    )

    XCTAssertEqual(sessions.count, 3)
    let session = try XCTUnwrap(
      sessions.first(where: { $0.projectID == "project-1" && $0.providerID == "antigravity" })
    )
    XCTAssertEqual(session.tasks.map(\.taskID), ["task-1", "task-2"])
    XCTAssertEqual(session.latestTask.taskID, "task-2")
    XCTAssertEqual(session.title, "检查 Windows 对齐")
    XCTAssertEqual(session.turnCount, 2)
    XCTAssertEqual(
      WorkbenchTaskTextPresentation.sessionMenuTitle(
        title: session.title,
        turnCount: session.turnCount
      ),
      "检查 Windows 对齐 [2轮]"
    )
  }

  func testProviderGroupsUseStablePreferredOrder() {
    let sessions = WorkbenchSessionCatalog.groupedSessions(tasks: [
      task(taskID: "dsh", providerID: "deepseek-harness", sessionID: "dsh-session"),
      task(taskID: "codex", providerID: "codex", sessionID: "codex-session"),
      task(taskID: "agy", providerID: "antigravity", sessionID: "agy-session"),
      task(taskID: "open", providerID: "opencode", sessionID: "open-session"),
    ])

    XCTAssertEqual(
      sessions.map(\.providerID),
      ["codex", "antigravity", "opencode", "deepseek-harness"]
    )
  }

  func testTaskActionPresentationSupportsCodexAndCapabilityGatedContinuation() {
    let codex = task(
      taskID: "codex-running",
      providerID: "codex",
      sessionID: "thread-1",
      status: "running",
      turnID: "turn-1"
    )
    let resumableAgent = task(
      taskID: "agent-failed",
      providerID: "antigravity",
      sessionID: "agy-session",
      prompt: "继续完成",
      status: "failed"
    )

    XCTAssertTrue(TaskInspectorPresentation.canSteer(codex, providerSupportsSteer: false))
    XCTAssertTrue(
      TaskInspectorPresentation.canResume(
        resumableAgent,
        providerSupportsSessionContinuation: true
      )
    )
    XCTAssertFalse(
      TaskInspectorPresentation.canResume(
        resumableAgent,
        providerSupportsSessionContinuation: false
      )
    )
    XCTAssertTrue(resumableAgent.canRestart)
  }

  func testTitleSanitizationRemovesProviderFailureNoise() {
    XCTAssertEqual(
      WorkbenchTaskTextPresentation.cleanTitle(
        "Antigravity could not run native tool 'view_file': timed out"
      ),
      "工具 view_file 执行异常"
    )
    XCTAssertEqual(
      WorkbenchTaskTextPresentation.cleanTitle(
        "The user denied this provider invocation request"
      ),
      "用户拒绝执行"
    )
  }

  private func task(
    taskID: String,
    projectID: String = "project-1",
    providerID: String,
    sessionID: String,
    prompt: String? = nil,
    status: String = "completed",
    turnID: String? = nil,
    updatedAt: String = "2026-09-04T00:00:00Z"
  ) -> MCPServiceTaskSnapshot {
    MCPServiceTaskSnapshot(
      taskID: taskID,
      projectID: projectID,
      prompt: prompt,
      status: status,
      providerID: providerID,
      threadID: providerID == "codex" ? sessionID : nil,
      turnID: turnID,
      providerSessionID: providerID == "codex" ? nil : sessionID,
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: updatedAt
    )
  }
}
