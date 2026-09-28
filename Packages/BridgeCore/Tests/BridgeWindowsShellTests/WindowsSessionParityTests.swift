#if os(Windows)
  import BridgeDesktopUI
  import XCTest

  @testable import BridgeWindowsShell

  final class WindowsSessionParityTests: XCTestCase {
    func testSessionRowCarriesLatestTaskAndWholeSessionCapabilities() {
      let row = BridgeDesktopTaskRow(
        taskID: "task-2",
        sessionID: "session-1",
        title: "修复构建",
        projectID: "project-1",
        projectName: "Bridge",
        source: "ChatGPT",
        provider: "Antigravity",
        providerID: "antigravity",
        status: "失败",
        updatedAt: "2026-09-04T02:00:00Z",
        turnCount: 2,
        canResume: true,
        canRestart: true,
        canDelete: true
      )

      XCTAssertEqual(row.sessionID, "session-1")
      XCTAssertEqual(row.turnCount, 2)
      XCTAssertTrue(row.canDelete)
      XCTAssertTrue(row.canResume)
      XCTAssertTrue(row.canRestart)
    }
  }
#endif
