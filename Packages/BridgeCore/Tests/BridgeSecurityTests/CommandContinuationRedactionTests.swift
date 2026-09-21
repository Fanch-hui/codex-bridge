import XCTest

@testable import BridgeSecurity

final class CommandContinuationRedactionTests: XCTestCase {
  func testCredentialLabelFromPriorChunkStillRedactsItsContinuation() {
    let value = OutboundContentSecurity.redactedCommandContinuation(
      context: "API_KEY=example-", delta: "credential\nBuild completed", maximumUTF8Bytes: 1024)
    XCTAssertEqual(value, "[REDACTED]\nBuild completed")
  }
}
