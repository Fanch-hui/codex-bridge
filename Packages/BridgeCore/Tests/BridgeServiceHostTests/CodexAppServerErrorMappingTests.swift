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
}
