import XCTest

@testable import BridgeServiceAppCore

final class ToolStatusPresentationTests: XCTestCase {
  func testCancelledAndDeclinedToolsDoNotClaimCompletion() {
    for status in ["cancelled", "declined", "interrupted", "denied"] {
      let presentation = CodexTranscriptPresentation.tool(
        providerID: "antigravity", name: "run_command", status: status)
      XCTAssertEqual(presentation.title, "运行命令")
      XCTAssertFalse(CodexTranscriptPresentation.isActive(status))
      XCTAssertNotEqual(CodexTranscriptPresentation.statusLabel(status), "失败")
    }
  }

  func testActiveAndUnknownStatusesRemainDistinct() {
    XCTAssertEqual(CodexTranscriptPresentation.statusLabel("in_progress"), "进行中")
    XCTAssertEqual(CodexTranscriptPresentation.statusLabel("queued"), "等待执行")
    XCTAssertEqual(CodexTranscriptPresentation.statusLabel("unrecognized"), "状态未知")
    XCTAssertEqual(CodexTranscriptPresentation.statusLabel("failed"), "失败")
    XCTAssertEqual(CodexTranscriptPresentation.statusLabel("succeeded"), "")
    XCTAssertFalse(CodexTranscriptPresentation.isActive("unrecognized"))
  }
}
