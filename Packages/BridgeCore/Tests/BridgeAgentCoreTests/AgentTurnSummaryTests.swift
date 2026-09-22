import BridgeAgentCore
import XCTest

final class AgentTurnSummaryTests: XCTestCase {
  func testSingleTurnSummaryKeepsItsExactBytes() {
    XCTAssertEqual(AgentTurnSummary.combined([" 报告完成 "]), " 报告完成 ")
  }

  func testEveryTurnReplySurvivesInChronologicalOrder() {
    XCTAssertEqual(
      AgentTurnSummary.combined(["第一轮", "", "  ", "第二轮", "第三轮"]),
      "第一轮\n\n---\n\n第二轮\n\n---\n\n第三轮"
    )
  }

  func testBlankTurnsProduceNoSummary() {
    XCTAssertNil(AgentTurnSummary.combined([]))
    XCTAssertNil(AgentTurnSummary.combined(["", "  \n "]))
  }

  func testOverflowDropsTheTailInsteadOfTheEarliestTurns() {
    let combined = AgentTurnSummary.combined(["aaaa", "bbbb"], maximumUTF8Bytes: 10)
    XCTAssertEqual(combined?.utf8.count, 10)
    XCTAssertTrue(combined?.hasPrefix("aaaa") == true)
  }
}
