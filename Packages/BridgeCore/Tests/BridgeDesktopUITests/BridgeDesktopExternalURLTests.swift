import XCTest

@testable import BridgeDesktopUI

final class BridgeDesktopExternalURLTests: XCTestCase {
  func testReplyLinksOnlyOpenWebAddresses() {
    XCTAssertEqual(
      BridgeDesktopExternalURL.resolve("https://example.com/docs?q=swift")?.host,
      "example.com")
    XCTAssertNotNil(BridgeDesktopExternalURL.resolve("http://localhost:8080/result"))
    XCTAssertNil(BridgeDesktopExternalURL.resolve("javascript:alert(1)"))
    XCTAssertNil(BridgeDesktopExternalURL.resolve("file:///tmp/result"))
  }

  func testApprovalLabelsPreserveTheDecisionScope() {
    let row = BridgeDesktopApprovalRow(
      approvalID: "approval", kind: "command", title: "执行命令", summary: "git status",
      decisionOptions: ["allow", "allow_for_session", "allow_similar_commands", "deny"])
    XCTAssertEqual(row.decisionLabels?["allow"], "仅本次允许")
    XCTAssertEqual(row.decisionLabels?["allow_for_session"], "本次会话允许")
    XCTAssertEqual(row.decisionLabels?["allow_similar_commands"], "允许此类命令")
    XCTAssertEqual(row.decisionLabels?["deny"], "拒绝")
  }
}
