import BridgeAgentCore
import BridgeDomain
import BridgeServiceCore
import XCTest

@testable import BridgeCodexService

final class AgentTaskBriefApprovalTests: XCTestCase {
  func testExternalProvidersKeepNativeApprovalForStoredCodexAccessModes() {
    for providerID in [AgentProviderID.antigravity, .openCode, .deepSeekHarness] {
      for accessMode in [ServiceAccessMode.fullAccess, .requestApproval, .autoReview] {
        for networkAllowed in [true, false] {
          let brief = AgentTaskBrief(
            taskID: TaskID(rawValue: "task-agent-approval"),
            providerID: providerID,
            installationID: AgentInstallationID(rawValue: "installation-agent-approval"),
            projectID: ProjectID(rawValue: "project-agent-approval"),
            projectRoot: "/tmp",
            prompt: "Inspect the project.",
            networkAllowed: networkAllowed,
            accessMode: accessMode
          )
          XCTAssertEqual(brief.toolApprovalPolicy, .providerManaged)
          XCTAssertEqual(brief.networkAllowed, networkAllowed)
        }
      }
    }
  }
}
