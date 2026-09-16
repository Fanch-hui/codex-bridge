import BridgeAgentCore
import BridgeDomain
import XCTest

@testable import BridgeAntigravityCLI

final class AntigravityToolStateTests: XCTestCase {
  func testToolCancellationAndPermissionDenialHaveDistinctStates() async throws {
    let cases: [(String, String, AgentToolStatus)] = [
      ("CANCELED", "null", .cancelled),
      ("DONE", #"{"type":"cancelled","message":"Stopped by user"}"#, .cancelled),
      ("DONE", #"{"type":"permission","message":"requires approval"}"#, .declined),
      ("DONE", "{}", .completed),
      ("ERROR", #"{"type":"execution","message":"Process failed"}"#, .failed),
    ]
    for (state, error, expected) in cases {
      let normalizer = try makeNormalizer()
      let wire = try AntigravityCLITestSupport.decode(
        AntigravityStreamEnvelope.self,
        """
        {"event":"step_update","step_update":{"conversation_id":"conversation-1",\
        "step_index":0,"state":"\(state)","step_type":"tool","tool_name":"run_command",\
        "tool_info":{"name":"run_command","parameters":{"command":"git status"},"error":\(error)}}}
        """
      )
      let events = try await normalizer.normalize(XCTUnwrap(wire.stepUpdate))
      guard case .tool(let tool) = try XCTUnwrap(events.first).event else {
        return XCTFail("Expected a tool update")
      }
      XCTAssertEqual(tool.status, expected)
      XCTAssertTrue(tool.arguments?.contains("git status") == true)
    }
  }

  private func makeNormalizer() throws -> AntigravityCLIEventNormalizer {
    let binding = try AgentBinding(
      providerID: .antigravity,
      installationID: AgentInstallationID(rawValue: "agy-test"),
      providerSessionID: "conversation-1",
      providerRunID: "run-1"
    )
    return AntigravityCLIEventNormalizer(
      taskID: TaskID(rawValue: "task-tool-states"), binding: binding, projectRoot: "/tmp/project")
  }
}
