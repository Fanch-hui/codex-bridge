import Foundation
import XCTest

@testable import BridgeSecurity

final class ToolArgumentRedactionTests: XCTestCase {
  func testJSONCommandRetainsAbsolutePathsAndArguments() {
    let input =
      #"{"command":"/usr/bin/git -C /Users/alice/project status --porcelain","cwd":"/Users/alice/project"}"#

    let redacted = OutboundContentSecurity.redactedToolArguments(
      input,
      maximumUTF8Bytes: 4_096
    )

    XCTAssertTrue(redacted.contains(#"/usr/bin/git -C /Users/alice/project status --porcelain"#))
    XCTAssertTrue(redacted.contains(#""cwd":"/Users/alice/project""#))
  }

  func testNestedJSONSecretsAreReplacedWhileCommandRemains() {
    let input =
      #"{"tool":{"command":"/usr/bin/curl https://example.test","headers":{"Authorization":"Bearer nested-secret"},"credentials":{"api_key":"sk-test-secret-value"}}}"#

    let redacted = OutboundContentSecurity.redactedToolArguments(
      input,
      maximumUTF8Bytes: 4_096
    )

    XCTAssertTrue(redacted.contains(#"/usr/bin/curl https://example.test"#))
    XCTAssertFalse(redacted.contains("nested-secret"))
    XCTAssertFalse(redacted.contains("sk-test-secret-value"))
    XCTAssertEqual(redacted.components(separatedBy: "[REDACTED]").count - 1, 2)
  }

  func testBearerSecretInsideCommandStringIsRedacted() {
    let input =
      #"{"command":"curl -H \"Authorization: Bearer real-bearer-secret\" https://example.test"}"#

    let redacted = OutboundContentSecurity.redactedToolArguments(
      input,
      maximumUTF8Bytes: 4_096
    )

    XCTAssertTrue(redacted.contains("curl"))
    XCTAssertTrue(redacted.contains("https://example.test"))
    XCTAssertFalse(redacted.contains("real-bearer-secret"))
    XCTAssertTrue(redacted.contains("[REDACTED]"))
  }

  func testStructuredCommandArgumentsRedactFollowingSecretValue() {
    let redacted = OutboundContentSecurity.redactedCommandArguments([
      "/usr/bin/tool",
      "--token",
      "plain-secret-value",
      "--mode",
      "safe",
      "--api_key=another-secret",
    ])

    XCTAssertEqual(
      redacted,
      ["/usr/bin/tool", "--token", "[REDACTED]", "--mode", "safe", "--api_key=[REDACTED]"]
    )
  }
}
