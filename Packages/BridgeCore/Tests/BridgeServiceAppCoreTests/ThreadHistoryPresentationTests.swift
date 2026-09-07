import BridgeMCP
import BridgeServiceAppCore
import XCTest

final class ThreadHistoryPresentationTests: XCTestCase {
  func testHistoryPreservesTranscriptOrderTextAndRoles() {
    let thread = MCPThreadSummary(threadID: "history-1", status: "idle", preview: "历史会话")
    let page = MCPThreadReadPage(
      thread: thread,
      detail: .full,
      entries: [
        MCPThreadEntry(turnID: "turn-1", role: "user", text: "检查项目"),
        MCPThreadEntry(turnID: "turn-1", role: "assistant", text: "检查完成"),
        MCPThreadEntry(turnID: "turn-1", role: "system", text: "会话信息"),
      ]
    )
    let entries = ThreadHistoryPresentation.entries(page)
    XCTAssertEqual(ThreadHistoryPresentation.title(thread), "历史会话")
    XCTAssertEqual(entries.map(\.text), ["检查项目", "检查完成", "会话信息"])
    XCTAssertEqual(entries.map(\.role), ["用户", "Codex", "system"])
    XCTAssertEqual(
      entries.map(\.id), ["thread:history-1:0", "thread:history-1:1", "thread:history-1:2"])
  }
}
