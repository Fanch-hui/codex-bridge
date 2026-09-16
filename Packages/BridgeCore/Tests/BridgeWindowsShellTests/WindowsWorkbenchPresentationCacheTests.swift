#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore
  import XCTest

  @testable import BridgeWindowsShell

  final class WindowsWorkbenchPresentationCacheTests: XCTestCase {
    func testTaskIndexesAndSessionGroupingRespectProjectSelection() {
      let tasks = [
        makeTask(
          id: "task-1", projectID: "project-a", sessionID: "session-a",
          updatedAt: "2026-09-16T00:01:00Z"),
        makeTask(
          id: "task-2", projectID: "project-a", sessionID: "session-a",
          updatedAt: "2026-09-16T00:02:00Z"),
        makeTask(
          id: "task-3", projectID: "project-b", sessionID: "session-b",
          updatedAt: "2026-09-16T00:03:00Z"),
      ]
      let projects = [
        MCPProjectSummary(
          projectID: "project-a",
          name: "A",
          capabilities: MCPProjectCapabilities(read: "allowed", write: "allowed", network: "denied")
        ),
        MCPProjectSummary(
          projectID: "project-b",
          name: "B",
          capabilities: MCPProjectCapabilities(read: "allowed", write: "allowed", network: "denied")
        ),
      ]
      var cache = WindowsWorkbenchPresentationCache()
      let first = cache.snapshot(
        tasks: tasks,
        projects: projects,
        providers: [],
        installations: [],
        approvals: [],
        directApprovals: [],
        selectedProjectID: "project-a"
      )
      let second = cache.snapshot(
        tasks: tasks,
        projects: projects,
        providers: [],
        installations: [],
        approvals: [],
        directApprovals: [],
        selectedProjectID: "project-b"
      )

      XCTAssertEqual(first.taskByID["task-2"]?.taskID, "task-2")
      XCTAssertEqual(first.visibleSessions.count, 1)
      XCTAssertEqual(first.visibleSessions.first?.turnCount, 2)
      XCTAssertEqual(first.projectName(for: "project-a"), "A")
      XCTAssertEqual(second.visibleTasks.map(\.taskID), ["task-3"])
      XCTAssertEqual(second.visibleSessions.first?.sessionID, "session-b")
    }

    func testConversationCacheOnlyRebuildsChangedAndAppendedEntries() {
      let firstEntry = TaskConversationModel.Entry(
        key: "message-1", role: "agent", kind: "agent", content: "first", isFinal: true
      )
      let streamingEntry = TaskConversationModel.Entry(
        key: "message-2", role: "agent", kind: "agent", content: "part", isFinal: false
      )
      var cache = WindowsConversationPresentationCache()
      let initial = cache.update(
        taskID: "task-1",
        providerID: "codex",
        entries: [firstEntry, streamingEntry]
      )

      var finishedEntry = streamingEntry
      finishedEntry.content = "complete"
      finishedEntry.isFinal = true
      let updated = cache.update(
        taskID: "task-1",
        providerID: "codex",
        entries: [firstEntry, finishedEntry]
      )
      XCTAssertEqual(updated[0], initial[0])
      XCTAssertNotEqual(updated[1], initial[1])
      XCTAssertEqual(
        cache.text(isStreaming: false, errorMessage: nil), "Agent：first\r\n\r\nAgent：complete")

      let appendedEntry = TaskConversationModel.Entry(
        key: "message-3", role: "user", kind: "agent", content: "next", isFinal: true
      )
      let appended = cache.update(
        taskID: "task-1",
        providerID: "codex",
        entries: [firstEntry, finishedEntry, appendedEntry]
      )
      XCTAssertEqual(appended.count, 3)
      XCTAssertEqual(appended[0], updated[0])
      XCTAssertEqual(appended[1], updated[1])
      XCTAssertEqual(appended[2].text, "next")
    }

    private func makeTask(
      id: String,
      projectID: String,
      sessionID: String,
      updatedAt: String
    ) -> MCPServiceTaskSnapshot {
      MCPServiceTaskSnapshot(
        taskID: id,
        projectID: projectID,
        status: "completed",
        providerID: "codex",
        threadID: sessionID,
        supervisorStatus: "disabled",
        localApprovalRequired: false,
        updatedAt: updatedAt
      )
    }
  }
#endif
