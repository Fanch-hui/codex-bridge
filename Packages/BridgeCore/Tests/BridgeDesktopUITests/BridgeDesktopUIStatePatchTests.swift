import BridgeDesktopUI
import XCTest

final class BridgeDesktopUIStatePatchTests: XCTestCase {
  func testStreamingConversationUpdateUsesOneEntryPatch() throws {
    let entries = (0..<96).map { index in
      conversationEntry(id: "entry-\(index)", text: String(repeating: "正文 ", count: 32))
    }
    var builder = BridgeDesktopUIStatePatchBuilder()
    let initial = builder.makePatch(state: makeState(entries: entries), nextRevision: 1)

    var updatedEntries = entries
    updatedEntries[95] = conversationEntry(
      id: "entry-95",
      text: String(repeating: "正文 ", count: 32) + "新增内容"
    )
    let patch = builder.makePatch(state: makeState(entries: updatedEntries), nextRevision: 2)
    let initialSize = try JSONEncoder().encode(initial).count
    let patchData = try JSONEncoder().encode(patch)

    XCTAssertTrue(initial.isFull)
    XCTAssertFalse(patch.isFull)
    XCTAssertEqual(patch.baseRevision, 1)
    XCTAssertEqual(patch.nextRevision, 2)
    XCTAssertEqual(patch.changes.count, 1)
    XCTAssertEqual(patch.changes.first?.entries?.count, 1)
    XCTAssertLessThan(patchData.count, initialSize / 4)
  }

  func testRevisionGapFallsBackToFullSnapshot() {
    var builder = BridgeDesktopUIStatePatchBuilder()
    _ = builder.makePatch(state: makeState(entries: []), nextRevision: 1)
    let patch = builder.makePatch(
      state: makeState(entries: [conversationEntry(id: "entry-1", text: "内容")]),
      nextRevision: 4
    )

    XCTAssertTrue(patch.isFull)
    XCTAssertNil(patch.baseRevision)
    XCTAssertEqual(patch.nextRevision, 4)
    XCTAssertEqual(patch.state?.workbench?.selectedTask?.conversation.count, 1)
  }

  private func makeState(entries: [BridgeDesktopConversationEntry]) -> BridgeDesktopUIState {
    let task = BridgeDesktopTaskDetail(
      taskID: "task-1",
      title: "测试任务",
      projectName: "项目",
      status: "运行中",
      isTerminal: false,
      provider: "Codex",
      providerID: "codex",
      conversation: entries,
      updatedAt: "2026-09-21T00:00:00Z"
    )
    return BridgeDesktopUIState(
      selectedNavigation: .workbench,
      connectionLabel: "已连接",
      connectionTone: .success,
      isRefreshing: false,
      overview: nil,
      workbench: BridgeDesktopWorkbenchState(
        header: BridgeDesktopPageHeader(
          title: "工作台",
          subtitle: "任务",
          symbol: "bubble.left"
        ),
        selectedTaskID: task.taskID,
        selectedTask: task
      )
    )
  }

  private func conversationEntry(id: String, text: String) -> BridgeDesktopConversationEntry {
    BridgeDesktopConversationEntry(
      id: id,
      role: "Codex",
      text: text,
      kind: "message",
      isFinal: false,
      status: "streaming"
    )
  }
}
