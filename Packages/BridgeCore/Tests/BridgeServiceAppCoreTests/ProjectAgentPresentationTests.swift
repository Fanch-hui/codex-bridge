import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore
import XCTest

final class ProjectAgentPresentationTests: XCTestCase {
  func testProjectPresentationKeepsStableIDAndPolicyValues() {
    let project = MCPProjectSummary(
      projectID: "project-1",
      name: "Bridge",
      capabilities: MCPProjectCapabilities(
        read: "allowed",
        write: "requiresLocalApproval",
        network: "denied"
      ),
      gitState: "clean"
    )

    let item = ProjectAgentPresentation.project(project)

    XCTAssertEqual(item.id, "project-1")
    XCTAssertTrue(item.rowText.contains("Bridge"))
    XCTAssertEqual(item.readPermission, "allowed")
    XCTAssertTrue(item.detailText.contains("写入：需要本机批准"))
    XCTAssertTrue(item.detailText.contains("Git：Git 干净"))
  }

  func testProviderPresentationExposesRegistrationAndCapabilities() {
    let provider = IPCAgentProviderSummary(
      providerID: "deepseek-harness",
      displayName: "DeepSeek Harness",
      adapterRevision: 3,
      requiresConfiguration: true,
      supportsSteer: true,
      supportsSkillSelection: true
    )

    let item = ProjectAgentPresentation.provider(provider)

    XCTAssertEqual(item.id, "deepseek-harness")
    XCTAssertTrue(item.requiresConfiguration)
    XCTAssertTrue(item.detailText.contains("需要配置文件"))
    XCTAssertTrue(item.detailText.contains("Steer"))
    XCTAssertTrue(item.detailText.contains("技能"))
  }

  func testInstallationPresentationKeepsStableIDAndProbeDetails() {
    let installation = IPCAgentInstallationSummary(
      installationID: "install-1",
      providerID: "opencode",
      displayName: "OpenCode",
      executablePath: "C:\\Tools\\opencode.exe",
      version: "1.2.3",
      protocolRevision: "acp-1",
      adapterRevision: 4,
      trustProfile: "managed",
      isEnabled: false,
      availability: "needs_review",
      effectiveCapabilities: ["selection.model", "selection.effort"],
      lastProbeError: "文件身份发生变化",
      updatedAt: "2026-08-30T00:00:00Z"
    )

    let item = ProjectAgentPresentation.installation(installation)

    XCTAssertEqual(item.id, "install-1")
    XCTAssertFalse(item.isEnabled)
    XCTAssertEqual(item.availability, "needs_review")
    XCTAssertTrue(item.rowText.contains("需复核"))
    XCTAssertTrue(item.detailText.contains("C:\\Tools\\opencode.exe"))
    XCTAssertTrue(item.detailText.contains("Probe 错误：文件身份发生变化"))
  }

  func testUnknownLabelsRemainVisible() {
    XCTAssertEqual(ProjectAgentPresentation.permissionLabel("future"), "未知：future")
    XCTAssertEqual(ProjectAgentPresentation.availabilityLabel("future"), "未知：future")
    XCTAssertEqual(ProjectAgentPresentation.availabilityLabel("incompatible"), "不兼容")
  }

  func testReconnectRequirementOnlyIncludesEnabledUnavailableInstallations() {
    XCTAssertTrue(
      ProjectAgentPresentation.requiresReconnect(
        isEnabled: true,
        availability: "needs_review"
      )
    )
    XCTAssertTrue(
      ProjectAgentPresentation.requiresReconnect(
        isEnabled: true,
        availability: "incompatible"
      )
    )
    XCTAssertFalse(
      ProjectAgentPresentation.requiresReconnect(
        isEnabled: false,
        availability: "unavailable"
      )
    )
    XCTAssertEqual(
      ProjectAgentPresentation.reconnectSummary(names: ["AGY CLI"]),
      "AGY CLI 需要重新连接"
    )
    XCTAssertEqual(
      ProjectAgentPresentation.reconnectSummary(names: ["AGY CLI", "OpenCode"]),
      "AGY CLI、OpenCode 需要重新连接"
    )
  }
}
