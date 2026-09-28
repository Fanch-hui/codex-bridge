import BridgeServiceAppCore
import XCTest

final class TaskConversationPresentationUpdatePlanTests: XCTestCase {
  func testPlanIdentifiesChangedAndAppendedEntries() {
    let first = entry("first", content: "before")
    let second = entry("second", content: "streaming")
    var updatedSecond = second
    updatedSecond.content = "complete"
    updatedSecond.isFinal = true
    let appended = entry("third", content: "next")

    let plan = TaskConversationPresentationUpdatePlan(
      previous: [first, second],
      next: [first, updatedSecond, appended]
    )

    XCTAssertFalse(plan.needsFullRebuild)
    XCTAssertEqual(plan.changedEntryIndices, [1])
    XCTAssertEqual(plan.appendedEntryRange, 2..<3)
  }

  func testPlanRequiresRebuildWhenEntriesAreRemovedOrReordered() {
    let first = entry("first", content: "one")
    let second = entry("second", content: "two")

    let truncated = TaskConversationPresentationUpdatePlan(
      previous: [first, second],
      next: [first]
    )
    let reordered = TaskConversationPresentationUpdatePlan(
      previous: [first, second],
      next: [second, first]
    )

    XCTAssertTrue(truncated.needsFullRebuild)
    XCTAssertTrue(reordered.needsFullRebuild)
  }

  private func entry(_ key: String, content: String) -> TaskConversationModel.Entry {
    TaskConversationModel.Entry(
      key: key,
      role: "agent",
      kind: "agent",
      content: content,
      isFinal: false
    )
  }
}
