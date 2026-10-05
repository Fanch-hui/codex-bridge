@testable import BridgeDesktopUI
import Foundation
import Testing

@Suite("BridgeDesktopUIStatePatchBuilder full vs incremental")
struct BridgeDesktopUIStatePatchBuilderTests {

  private func makeWorkbench(
    browser: BridgeDesktopBrowserSlot = BridgeDesktopBrowserSlot(
      visible: true, enabled: true, url: nil, status: "由宿主加载 ChatGPT 工作区"),
    tasks: [BridgeDesktopTaskRow] = [],
    approvals: [BridgeDesktopApprovalRow] = [],
    selectedTaskID: String? = nil,
    selectedTask: BridgeDesktopTaskDetail? = nil,
    permissionMode: String = "workspace-write"
  ) -> BridgeDesktopWorkbenchState {
    BridgeDesktopWorkbenchState(
      header: BridgeDesktopPageHeader(title: "Workbench", subtitle: "", symbol: "star"),
      permissionMode: permissionMode,
      tasks: tasks,
      selectedTaskID: selectedTaskID,
      selectedTask: selectedTask,
      approvals: approvals,
      browser: browser
    )
  }

  private func makeState(
    workbench: BridgeDesktopWorkbenchState = nil,
    overview: BridgeDesktopOverviewState? = nil
  ) -> BridgeDesktopUIState {
    BridgeDesktopUIState(
      selectedNavigation: .workbench,
      connectionLabel: "已连接",
      connectionTone: .neutral,
      isRefreshing: false,
      overview: overview,
      workbench: workbench
    )
  }

  private func makeBrowser(url: String?) -> BridgeDesktopBrowserSlot {
    BridgeDesktopBrowserSlot(visible: true, enabled: true, url: url, status: "加载中")
  }

  private func makeTask(
    updatedAt: String = "2026-01-01T00:00:00Z",
    conversation: [BridgeDesktopConversationEntry] = []
  ) -> BridgeDesktopTaskDetail {
    BridgeDesktopTaskDetail(
      taskID: "task-1",
      title: "Task One",
      projectName: "Proj",
      status: "running",
      provider: "codex",
      conversation: conversation,
      updatedAt: updatedAt
    )
  }

  private func makeEntry(_ id: String, text: String = "hello") -> BridgeDesktopConversationEntry {
    BridgeDesktopConversationEntry(id: id, role: "assistant", text: text)
  }

  private func makeRow(
    _ id: String, title: String, status: String, updatedAt: String
  ) -> BridgeDesktopTaskRow {
    BridgeDesktopTaskRow(
      taskID: id,
      title: title,
      projectID: "p",
      projectName: "P",
      source: "codex",
      provider: "codex",
      status: status,
      updatedAt: updatedAt
    )
  }

  // MARK: full snapshots

  @Test("the first frame is always a full snapshot")
  func firstFrameIsFull() {
    var builder = BridgeDesktopUIStatePatchBuilder()
    let state = makeState()
    let patch = builder.makePatch(state: state, nextRevision: 1)
    #expect(patch.isFull)
    #expect(patch.state == state)
    #expect(patch.baseRevision == nil)
    #expect(patch.changes.isEmpty)
  }

  @Test("revision gaps fall back to a full snapshot")
  func revisionGapIsFull() {
    var builder = BridgeDesktopUIStatePatchBuilder()
    _ = builder.makePatch(state: makeState(), nextRevision: 4)
    let patch = builder.makePatch(state: makeState(), nextRevision: 6)
    #expect(patch.isFull)
  }

  @Test("identical consecutive states fall back to a full snapshot")
  func identicalStateIsFull() {
    var builder = BridgeDesktopUIStatePatchBuilder()
    let state = makeState()
    _ = builder.makePatch(state: state, nextRevision: 1)
    let patch = builder.makePatch(state: state, nextRevision: 2)
    #expect(patch.isFull)
  }

  // MARK: incremental patches

  @Test("browser-only changes produce a single browser change")
  func browserOnlyPatch() {
    var builder = BridgeDesktopUIStatePatchBuilder()
    _ = builder.makePatch(
      state: makeState(workbench: makeWorkbench(browser: makeBrowser(url: nil))),
      nextRevision: 1)
    let newBrowser = makeBrowser(url: "https://example.dev")
    let patch = builder.makePatch(
      state: makeState(workbench: makeWorkbench(browser: newBrowser)),
      nextRevision: 2)
    #expect(!patch.isFull)
    #expect(patch.baseRevision == 1)
    #expect(patch.nextRevision == 2)
    #expect(patch.changes == [.browser(newBrowser)])
  }

  @Test("changed task rows produce an upsert patch")
  func taskRowsUpsert() {
    var builder = BridgeDesktopUIStatePatchBuilder()
    let rowA = makeRow("a", title: "A", status: "running", updatedAt: "t1")
    _ = builder.makePatch(
      state: makeState(workbench: makeWorkbench(tasks: [rowA])), nextRevision: 1)
    let rowA2 = makeRow("a", title: "A changed", status: "done", updatedAt: "t2")
    let rowB = makeRow("b", title: "B", status: "running", updatedAt: "t3")
    let patch = builder.makePatch(
      state: makeState(workbench: makeWorkbench(tasks: [rowA2, rowB])), nextRevision: 2)
    #expect(!patch.isFull)
    #expect(patch.changes == [.taskRows(mode: .upsert, rows: [rowA2, rowB], removedIDs: [])])
  }

  @Test("removed task rows report the removed ids")
  func taskRowsRemoval() {
    var builder = BridgeDesktopUIStatePatchBuilder()
    let rowA = makeRow("a", title: "A", status: "done", updatedAt: "t1")
    let rowB = makeRow("b", title: "B", status: "done", updatedAt: "t2")
    _ = builder.makePatch(
      state: makeState(workbench: makeWorkbench(tasks: [rowA, rowB])), nextRevision: 1)
    let patch = builder.makePatch(
      state: makeState(workbench: makeWorkbench(tasks: [rowA])), nextRevision: 2)
    #expect(patch.changes == [.taskRows(mode: .upsert, rows: [], removedIDs: ["b"])])
  }

  @Test("reordered task rows fall back to a replace patch")
  func taskRowsReorderReplaces() {
    var builder = BridgeDesktopUIStatePatchBuilder()
    let rowA = makeRow("a", title: "A", status: "done", updatedAt: "t1")
    let rowB = makeRow("b", title: "B", status: "done", updatedAt: "t2")
    _ = builder.makePatch(
      state: makeState(workbench: makeWorkbench(tasks: [rowA, rowB])), nextRevision: 1)
    let patch = builder.makePatch(
      state: makeState(workbench: makeWorkbench(tasks: [rowB, rowA])), nextRevision: 2)
    #expect(patch.changes == [.taskRows(mode: .replace, rows: [rowB, rowA], removedIDs: [])])
  }

  @Test("approval changes carry the full row list")
  func approvalsReplace() {
    var builder = BridgeDesktopUIStatePatchBuilder()
    _ = builder.makePatch(
      state: makeState(workbench: makeWorkbench(approvals: [])), nextRevision: 1)
    let approval = BridgeDesktopApprovalRow(
      approvalID: "ap-1", kind: "command", title: "Run make", summary: "make build")
    let patch = builder.makePatch(
      state: makeState(workbench: makeWorkbench(approvals: [approval])), nextRevision: 2)
    #expect(patch.changes == [.approvals([approval])])
  }

  // MARK: conversation patches

  @Test("appended conversation entries are sent as an upsert")
  func conversationAppend() {
    var builder = BridgeDesktopUIStatePatchBuilder()
    let first = makeEntry("e1")
    _ = builder.makePatch(
      state: makeState(
        workbench: makeWorkbench(selectedTaskID: "task-1", selectedTask: makeTask(conversation: [first]))),
      nextRevision: 1)
    let second = makeEntry("e2")
    let patch = builder.makePatch(
      state: makeState(
        workbench: makeWorkbench(
          selectedTaskID: "task-1",
          selectedTask: makeTask(conversation: [first, second]))),
      nextRevision: 2)
    #expect(!patch.isFull)
    #expect(
      patch.changes
        == [
          .conversation(
            taskID: "task-1", mode: .upsert, entries: [second], removedIDs: [], state: nil)
        ])
  }

  @Test("removed conversation entries are reported")
  func conversationRemoval() {
    var builder = BridgeDesktopUIStatePatchBuilder()
    let first = makeEntry("e1")
    let second = makeEntry("e2")
    _ = builder.makePatch(
      state: makeState(
        workbench: makeWorkbench(
          selectedTaskID: "task-1",
          selectedTask: makeTask(conversation: [first, second]))),
      nextRevision: 1)
    let patch = builder.makePatch(
      state: makeState(
        workbench: makeWorkbench(
          selectedTaskID: "task-1", selectedTask: makeTask(conversation: [first]))),
      nextRevision: 2)
    #expect(
      patch.changes
        == [
          .conversation(
            taskID: "task-1", mode: .upsert, entries: [], removedIDs: ["e2"], state: nil)
        ])
  }

  @Test("reordered conversations replace the whole list")
  func conversationReorder() {
    var builder = BridgeDesktopUIStatePatchBuilder()
    let first = makeEntry("e1")
    let second = makeEntry("e2")
    _ = builder.makePatch(
      state: makeState(
        workbench: makeWorkbench(
          selectedTaskID: "task-1",
          selectedTask: makeTask(conversation: [first, second]))),
      nextRevision: 1)
    let patch = builder.makePatch(
      state: makeState(
        workbench: makeWorkbench(
          selectedTaskID: "task-1",
          selectedTask: makeTask(conversation: [second, first]))),
      nextRevision: 2)
    #expect(
      patch.changes
        == [
          .conversation(
            taskID: "task-1", mode: .replace, entries: [second, first], removedIDs: [],
            state: nil)
        ])
  }

  @Test("timestamp-only task detail changes fall back to a selectedTask change")
  func updatedAtOnlyChange() {
    var builder = BridgeDesktopUIStatePatchBuilder()
    _ = builder.makePatch(
      state: makeState(
        workbench: makeWorkbench(selectedTaskID: "task-1", selectedTask: makeTask(updatedAt: "t1"))),
      nextRevision: 1)
    let newerTask = makeTask(updatedAt: "t2")
    let patch = builder.makePatch(
      state: makeState(
        workbench: makeWorkbench(selectedTaskID: "task-1", selectedTask: newerTask)),
      nextRevision: 2)
    #expect(!patch.isFull)
    #expect(patch.changes == [.selectedTask(newerTask)])
  }

  @Test("selecting a different task falls back to a full snapshot")
  func selectionChangeIsFull() {
    var builder = BridgeDesktopUIStatePatchBuilder()
    _ = builder.makePatch(
      state: makeState(
        workbench: makeWorkbench(selectedTaskID: "task-1", selectedTask: makeTask())),
      nextRevision: 1)
    let other = BridgeDesktopTaskDetail(
      taskID: "task-2", title: "Two", projectName: "Proj", status: "running",
      provider: "codex", updatedAt: "t1")
    let patch = builder.makePatch(
      state: makeState(
        workbench: makeWorkbench(selectedTaskID: "task-2", selectedTask: other)),
      nextRevision: 2)
    #expect(patch.isFull)
  }

  @Test("workbench shell changes fall back to a full snapshot")
  func shellChangeIsFull() {
    var builder = BridgeDesktopUIStatePatchBuilder()
    _ = builder.makePatch(
      state: makeState(workbench: makeWorkbench(permissionMode: "workspace-write")),
      nextRevision: 1)
    let patch = builder.makePatch(
      state: makeState(workbench: makeWorkbench(permissionMode: "danger-full-access")),
      nextRevision: 2)
    #expect(patch.isFull)
  }

  // MARK: volatile global domains (issue #6 regression baseline)

  @Test("overview-only changes currently fall back to a full snapshot")
  func overviewChangeIsFullToday() {
    var builder = BridgeDesktopUIStatePatchBuilder()
    let oldOverview = BridgeDesktopOverviewState(
      title: "概览", subtitle: "", notices: [], metrics: [], services: [],
      recentTasks: [
        BridgeDesktopRecentTask(
          id: "a", title: "A", projectName: "P", source: "codex", status: "running",
          updatedAt: "t1")
      ], lastUpdatedAt: "t1")
    _ = builder.makePatch(state: makeState(overview: oldOverview), nextRevision: 1)
    let newOverview = BridgeDesktopOverviewState(
      title: "概览", subtitle: "", notices: [], metrics: [], services: [],
      recentTasks: [
        BridgeDesktopRecentTask(
          id: "a", title: "A", projectName: "P", source: "codex", status: "running",
          updatedAt: "t2")
      ], lastUpdatedAt: "t2")
    let patch = builder.makePatch(state: makeState(overview: newOverview), nextRevision: 2)
    #expect(patch.isFull)
  }

  // MARK: codable

  @Test("patches encode and decode losslessly")
  func patchCodableRoundTrip() throws {
    var builder = BridgeDesktopUIStatePatchBuilder()
    _ = builder.makePatch(
      state: makeState(workbench: makeWorkbench(browser: makeBrowser(url: nil))),
      nextRevision: 1)
    let patch = builder.makePatch(
      state: makeState(workbench: makeWorkbench(browser: makeBrowser(url: "https://example.dev"))),
      nextRevision: 2)
    let data = try JSONEncoder().encode(patch)
    let decoded = try JSONDecoder().decode(BridgeDesktopUIStatePatch.self, from: data)
    #expect(decoded == patch)
  }

  @Test("full snapshots encode and decode losslessly")
  func fullSnapshotCodableRoundTrip() throws {
    var builder = BridgeDesktopUIStatePatchBuilder()
    let state = makeState(
      overview: BridgeDesktopOverviewState(
        title: "概览", subtitle: "", notices: [], metrics: [], services: [], recentTasks: []))
    let patch = builder.makePatch(state: state, nextRevision: 3)
    let data = try JSONEncoder().encode(patch)
    let decoded = try JSONDecoder().decode(BridgeDesktopUIStatePatch.self, from: data)
    #expect(decoded == patch)
  }
}
