import BridgeAgentCore
import BridgeDomain
import BridgeProcess
import Foundation
import XCTest

@testable import BridgeAntigravityCLI

final class AntigravityCLIProbeTests: XCTestCase {
  private static let completeHelp =
    """
    --mode Set the agent execution mode (accept-edits, plan)
    --conversation Resume a previous conversation by ID
    --model Model for the current CLI session
    --effort Reasoning effort for the current CLI session (low|medium|high)
    --sandbox Run in a sandbox with terminal restrictions enabled
    --dangerously-skip-permissions Auto-approve all tool permission requests
    --input-format stream-json reads one NDJSON message per line and runs a turn for each
    --output-format stream-json
    """

  private struct ProbeOutcome {
    let result: AgentProbeResult
    let calls: [RecordingAntigravityCommandRunner.Call]
  }

  func testProbeUsesHelpCapabilitiesAcrossVersionChanges() async throws {
    for version in ["1.1.20", "1.2.0", "1.3.0", "2.0.0"] {
      let outcome = try await runProbe(version: version, help: Self.completeHelp)

      XCTAssertTrue(outcome.result.available, version)
      XCTAssertFalse(outcome.result.reviewRequired, version)
      XCTAssertEqual(outcome.result.installation.version, version)
      XCTAssertEqual(outcome.result.installation.protocolRevision, "stream-json-v1")
      XCTAssertEqual(outcome.result.installation.executablePath, "/bin/echo")
      XCTAssertTrue(outcome.result.capabilities.advertised.contains(.sessionContinue), version)
      XCTAssertTrue(outcome.result.capabilities.observed.contains(.sessionContinue), version)
      XCTAssertTrue(outcome.result.capabilities.effective.contains(.workspaceRead), version)
      XCTAssertTrue(
        outcome.result.capabilities.effective.contains(.workspaceWriteInPlace), version)
      XCTAssertTrue(outcome.result.capabilities.effective.contains(.sessionContinue), version)
      XCTAssertTrue(outcome.result.capabilities.effective.contains(.modelSelection), version)
      XCTAssertTrue(outcome.result.capabilities.effective.contains(.effortSelection), version)
      XCTAssertTrue(outcome.result.capabilities.effective.contains(.steer), version)
      XCTAssertFalse(outcome.result.capabilities.effective.contains(.textDelta), version)
      XCTAssertEqual(
        outcome.calls.map(\.argv),
        [["/bin/echo", "--version"], ["/bin/echo", "--help"]],
        version
      )
    }
  }

  func testProbeRejectsMissingRequiredHelpCapabilities() async throws {
    let variants: [(String, String)] = [
      (
        "stream-json",
        Self.completeHelp.replacingOccurrences(
          of:
            "--input-format stream-json reads one NDJSON message per line and runs a turn for each",
          with: "--input-format text reads one message"
        )
      ),
      (
        "plan mode",
        Self.completeHelp.replacingOccurrences(of: "(accept-edits, plan)", with: "(accept-edits)")
      ),
      (
        "sandbox",
        Self.completeHelp.replacingOccurrences(
          of: "--sandbox Run in a sandbox with terminal restrictions enabled\n",
          with: ""
        )
      ),
      (
        "permission bypass",
        Self.completeHelp.replacingOccurrences(
          of: "--dangerously-skip-permissions Auto-approve all tool permission requests\n",
          with: ""
        )
      ),
    ]

    for (missingCapability, help) in variants {
      let outcome = try await runProbe(version: "2.0.0", help: help)

      XCTAssertFalse(outcome.result.available, missingCapability)
      XCTAssertFalse(outcome.result.reviewRequired, missingCapability)
      XCTAssertTrue(
        outcome.result.unavailableReason?.contains("required protocol surface") == true,
        missingCapability
      )
    }
  }

  private func runProbe(version: String, help: String) async throws -> ProbeOutcome {
    let projectRoot = try AntigravityCLITestSupport.temporaryDirectory(prefix: "agy-probe-project")
    let home = try AntigravityCLITestSupport.temporaryDirectory(prefix: "agy-probe-home")
    defer {
      try? FileManager.default.removeItem(atPath: projectRoot)
      try? FileManager.default.removeItem(atPath: home)
    }

    let output = "agy version \(version)\n\(help)"
    let commandRunner = RecordingAntigravityCommandRunner(
      result: AntigravityCLITestSupport.commandResult(output: output)
    )
    let provider = try AntigravityCLIProvider(
      configuration: AntigravityCLIProviderConfiguration(
        launchBuilder: AntigravityCLILaunchBuilder(),
        commandRunner: commandRunner,
        sourceEnvironment: ["HOME": home, "TMPDIR": projectRoot]
      )
    )
    let installation = try AgentInstallation(
      id: AgentInstallationID(rawValue: "agy-probe"),
      providerID: .antigravity,
      executablePath: "/bin/echo"
    )
    let result = await provider.probe(
      try AgentProbeRequest(installation: installation, projectRoot: projectRoot)
    )
    return ProbeOutcome(result: result, calls: await commandRunner.calls())
  }
}
