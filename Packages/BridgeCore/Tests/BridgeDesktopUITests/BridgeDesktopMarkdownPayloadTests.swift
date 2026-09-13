import BridgeDesktopUI
import XCTest

final class BridgeDesktopMarkdownPayloadTests: XCTestCase {
  func testConversationPayloadBuildsRenderedHTMLFromTextAndStreamingState() {
    let finalEntry = BridgeDesktopConversationEntry(
      id: "message-1",
      role: "Codex",
      text: "**完成**",
      isFinal: true
    )
    let streamingEntry = BridgeDesktopConversationEntry(
      id: "message-2",
      role: "Codex",
      text: "**处理中",
      isFinal: false
    )

    XCTAssertEqual(finalEntry.markdownHTML, "<p><strong>完成</strong></p>")
    XCTAssertTrue(streamingEntry.markdownHTML?.contains("▍") == true)
    XCTAssertFalse(streamingEntry.markdownHTML?.contains("**") == true)
  }

  func testSkillPayloadBuildsRenderedDescription() {
    let skill = BridgeDesktopSkillRow(
      skillID: "skill-1",
      name: "示例",
      description: "# 说明"
    )

    XCTAssertEqual(skill.descriptionHTML, "<h3>说明</h3>")
  }
}
