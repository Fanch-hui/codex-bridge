import BridgeCodexService
import BridgeDomain
import BridgeIPC
import BridgeMCP
import XCTest

@testable import BridgeServiceHost

final class CodexAppServerErrorMappingTests: XCTestCase {
  func testDesktopSurfaceKeepsTheAppServerDetail() {
    let mapped = BridgeServiceRequestController.mapMCPQueryError(
      .codexAppServerUnavailable("Could not launch Codex app-server: C:\\Tools\\codex.exe")
    )

    XCTAssertEqual(mapped.code, "codex_app_server_unavailable")
    XCTAssertEqual(mapped.retryable, true)
    XCTAssertTrue(mapped.message.contains("C:\\Tools\\codex.exe"), mapped.message)
  }

  func testExecutionFailuresUseSharedRetryClassification() {
    let cases: [(ExecutionServiceError, String, Bool)] = [
      (.invalidRequest("userInput.response"), "invalid_state", false),
      (.projectPermissionDenied(ProjectID(rawValue: "project-1")), "invalid_state", false),
      (.bindingMismatch, "turn_mismatch", false),
      (.activeSession(TaskID(rawValue: "task-1")), "busy", true),
      (.turnStartTimedOut, "unavailable", true),
      (.processUnavailable, "unavailable", true),
    ]

    for (error, code, retryable) in cases {
      let mapped = BridgeServiceRequestController.map(error)
      XCTAssertEqual(mapped.code, code)
      XCTAssertEqual(mapped.retryable, retryable)
    }
  }
}
