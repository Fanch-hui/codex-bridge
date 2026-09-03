import BridgeAgentCore
import XCTest

@testable import BridgeAntigravityCLI

final class AntigravityCLIPermissionRemediationTests: XCTestCase {
  func testCommandUsesStructuredCommandAndRejectsAmbiguity() async throws {
    let store = AntigravityCLISettingsStore(sourceEnvironment: [:])

    let command = await store.remediation(
      toolName: "run_command",
      toolArguments: #"{"CommandLine":"git status"}"#
    )
    let ambiguous = await store.remediation(
      toolName: "run_command",
      toolArguments: #"{"command":"git status","CommandLine":"git diff"}"#
    )

    XCTAssertEqual(command?.action, "command")
    XCTAssertEqual(command?.target, "git status")
    XCTAssertEqual(command?.displayRule, "command(git status)")
    XCTAssertNil(ambiguous)
  }

  func testWebAndBrowserRulesKeepOnlyNormalizedHost() async {
    let store = AntigravityCLISettingsStore(sourceEnvironment: [:])

    let web = await store.remediation(
      toolName: "read_url_content",
      toolArguments: #"{"url":"https://Example.COM:8443/private?q=value#fragment"}"#
    )
    let browser = await store.remediation(
      toolName: "browser_action",
      toolArguments: #"{"target_url":"http://docs.example.com/page"}"#
    )

    XCTAssertEqual(web?.displayRule, "read_url(example.com:8443)")
    XCTAssertEqual(browser?.displayRule, "execute_url(docs.example.com)")
  }

  func testMCPRequiresUnambiguousServerAndTool() async {
    let store = AntigravityCLISettingsStore(sourceEnvironment: [:])

    let fromName = await store.remediation(
      toolName: "mcp__github__search_repositories",
      toolArguments: "{}"
    )
    let fromArguments = await store.remediation(
      toolName: "mcp",
      toolArguments: #"{"server":"docs","tool":"search"}"#
    )
    let conflicting = await store.remediation(
      toolName: "mcp__github__search",
      toolArguments: #"{"server":"other","tool":"search"}"#
    )

    XCTAssertEqual(fromName?.displayRule, "mcp(github/search_repositories)")
    XCTAssertEqual(fromArguments?.displayRule, "mcp(docs/search)")
    XCTAssertNil(conflicting)
  }

  func testSensitiveRedactedAndMalformedArgumentsHaveNoRemediation() async {
    let store = AntigravityCLISettingsStore(sourceEnvironment: [:])

    let sensitive = await store.remediation(
      toolName: "run_command",
      toolArguments: #"{"command":"curl -H 'Authorization: Bearer token' example.com"}"#
    )
    let redacted = await store.remediation(
      toolName: "run_command",
      toolArguments: #"{"command":"<redacted>"}"#
    )
    let credentialURL = await store.remediation(
      toolName: "read_url_content",
      toolArguments: #"{"url":"https://user:password@example.com/private"}"#
    )
    let malformed = await store.remediation(
      toolName: "run_command",
      toolArguments: "not-json"
    )

    XCTAssertNil(sensitive)
    XCTAssertNil(redacted)
    XCTAssertNil(credentialURL)
    XCTAssertNil(malformed)
  }
}
