import BridgeAgentCore
import XCTest

final class AgentChildRunTests: XCTestCase {
  func testToolMetadataRoundTripsWithoutChangingDisplayedArguments() throws {
    let child = try AgentChildRun(
      id: "turn-child",
      sessionID: "thread-child",
      name: "reviewer",
      status: "in_progress",
      summary: "检查实现",
      workspaceURLs: ["file:///tmp/project"]
    )
    let arguments = #"{"command":"git status","cwd":"/tmp/project"}"#
    let stored = try XCTUnwrap(
      AgentToolArgumentsEnvelope.encode(arguments: arguments, childRuns: [child])
    )
    let decoded = try XCTUnwrap(AgentToolArgumentsEnvelope.decode(stored))

    XCTAssertEqual(decoded.arguments, arguments)
    XCTAssertEqual(decoded.childRuns, [child])
    XCTAssertNotEqual(stored, arguments)
  }

  func testNoChildRunsLeavesExistingArgumentsUntouched() {
    let arguments = #"{"command":"git status"}"#
    XCTAssertEqual(
      AgentToolArgumentsEnvelope.encode(arguments: arguments, childRuns: []),
      arguments
    )
    XCTAssertNil(AgentToolArgumentsEnvelope.decode(arguments))
  }
}
