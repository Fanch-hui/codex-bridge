import XCTest

@testable import BridgeCodexService

final class ExecutionPathMatchingTests: XCTestCase {
  func testWindowsPathMatchingNormalizesSeparatorsAndCase() {
    XCTAssertTrue(
      ExecutionSession.pathsMatch(
        #"D:\Workspace\CodexBridge"#,
        #"d:/workspace/codexbridge"#,
        style: .windows
      )
    )
    XCTAssertTrue(
      ExecutionSession.pathsMatch(
        #"/D:/Workspace/CodexBridge/./"#,
        #"D:\workspace\codexbridge"#,
        style: .windows
      )
    )
    XCTAssertFalse(
      ExecutionSession.pathsMatch(
        #"D:\Workspace\CodexBridge"#,
        #"D:\Workspace\Other"#,
        style: .windows
      )
    )
    XCTAssertFalse(
      ExecutionSession.pathsMatch(
        #"CodexBridge"#,
        #"D:\Workspace\CodexBridge"#,
        style: .windows
      )
    )
  }

  func testPosixPathMatchingPreservesExactComparison() {
    XCTAssertTrue(ExecutionSession.pathsMatch("/tmp/project", "/tmp/project", style: .posix))
    XCTAssertFalse(ExecutionSession.pathsMatch("/tmp/project/.", "/tmp/project", style: .posix))
  }
}
