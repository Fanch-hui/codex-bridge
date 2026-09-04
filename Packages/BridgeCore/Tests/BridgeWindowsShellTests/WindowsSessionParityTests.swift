#if os(Windows)
  import BridgeDesktopUI
  import XCTest

  @testable import BridgeWindowsShell

  final class WindowsSessionParityTests: XCTestCase {
    func testRetryCommandsRouteWithStableTaskIdentity() {
      let resume = BridgeDesktopCommandEnvelope(
        requestID: "resume-1",
        command: .resumeTask,
        payload: .init(taskID: "task-1", input: "继续完成剩余测试")
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(for: resume),
        .resumeTask(id: "task-1", input: "继续完成剩余测试")
      )

      let restart = BridgeDesktopCommandEnvelope(
        requestID: "restart-1",
        command: .restartTask,
        payload: .init(taskID: "task-1")
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(for: restart),
        .restartTask(id: "task-1")
      )
    }

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
