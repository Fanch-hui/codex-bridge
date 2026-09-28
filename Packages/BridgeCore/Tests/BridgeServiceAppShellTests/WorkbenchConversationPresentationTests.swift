import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore
import XCTest

@testable import BridgeServiceAppShell

final class WorkbenchConversationPresentationTests: XCTestCase {
  func testSelectedTaskWinsWhileConversationModelIsTemporarilyEmpty() {
    XCTAssertEqual(
      WorkbenchConversationSource.resolve(
        hasSelectedTask: true,
        historicalEntryCount: 3
      ),
      .task
    )
  }

  func testHistoricalThreadEntryUsesUnifiedConversationEntryShape() {
    let entry = TaskConversationModel.Entry(
      historicalThreadEntry: MCPThreadEntry(
        turnID: "turn-1",
        role: "assistant",
        text: "最终回复"
      ),
      threadID: "thread-1",
      index: 0
    )

    XCTAssertEqual(entry.key, "history:thread-1:0")
    XCTAssertEqual(entry.role, "agent")
    XCTAssertEqual(entry.kind, "agent")
    XCTAssertEqual(entry.content, "最终回复")
    XCTAssertTrue(entry.isFinal)
  }

  func testSelectedCodexTaskWinsOverHistoricalThreadLabel() {
    let task = MCPServiceTaskSnapshot(
      taskID: "codex-task",
      projectID: "project-1",
      status: "completed",
      providerID: "codex",
      threadID: "thread-1",
      supervisorStatus: "disabled",
      localApprovalRequired: false,
      updatedAt: "2026-08-29T00:00:00Z"
    )

    let selected = WorkbenchSessionCatalog.selectedTask(
      tasks: [task],
      selectedTaskID: task.taskID
    )

    XCTAssertEqual(selected?.taskID, task.taskID)
    XCTAssertTrue(selected?.isCodexTask == true)
  }

  @MainActor
  func testDesktopConversationCacheReusesStableEntriesDuringStreaming() {
    let first = TaskConversationModel.Entry(
      key: "first", role: "agent", kind: "agent", content: "ready", isFinal: true
    )
    let streaming = TaskConversationModel.Entry(
      key: "second", role: "agent", kind: "agent", content: "part", isFinal: false
    )
    var cache = BridgeDesktopConversationPresentationCache()
    let initial = cache.update(taskID: "task", providerID: "codex", entries: [first, streaming])

    var completed = streaming
    completed.content = "complete"
    completed.isFinal = true
    let updated = cache.update(taskID: "task", providerID: "codex", entries: [first, completed])

    XCTAssertEqual(updated[0], initial[0])
    XCTAssertNotEqual(updated[1], initial[1])
  }
}
