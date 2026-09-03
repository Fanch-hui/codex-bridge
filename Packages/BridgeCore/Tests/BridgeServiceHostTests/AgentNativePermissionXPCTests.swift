import BridgeAgentCore
import BridgeIPC
import XCTest

@testable import BridgeServiceHost

final class AgentNativePermissionXPCTests: XCTestCase {
  func testNativePermissionMutationPayloadUsesStableWireNames() throws {
    let request = IPCAgentNativePermissionMutationRequest(
      installationID: "ainst-antigravity",
      expectedRevision: nil,
      operation: .addRule,
      effect: "allow",
      action: "read_url",
      target: "example.com"
    )
    let encoded = try JSONEncoder().encode(request)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )

    XCTAssertEqual(object["installation_id"] as? String, "ainst-antigravity")
    XCTAssertEqual(object["operation"] as? String, "add_rule")
    XCTAssertEqual(object["effect"] as? String, "allow")
    XCTAssertEqual(object["action"] as? String, "read_url")
    XCTAssertEqual(object["target"] as? String, "example.com")
    XCTAssertNil(object["expected_revision"])
  }

  func testNativePermissionSnapshotPreservesRiskAndRedactionMetadata() throws {
    let response = IPCAgentNativePermissionPolicyResponse(
      providerID: "antigravity",
      installationID: "ainst-antigravity",
      toolPermission: "proceed-in-sandbox",
      availableModes: [
        IPCAgentNativePermissionModeSummary(
          modeID: "always-proceed",
          displayName: "Always proceed",
          requiresConfirmation: true
        )
      ],
      availableActions: ["command"],
      rules: [
        IPCAgentNativePermissionRuleSummary(
          ruleID: "rule-1",
          effect: "allow",
          action: "command",
          target: "[redacted]",
          isEditable: false,
          isRedacted: true,
          requiresConfirmation: true
        )
      ],
      revision: "revision-1",
      warnings: ["A higher-priority rule takes precedence."]
    )

    let decoded = try JSONDecoder().decode(
      IPCAgentNativePermissionPolicyResponse.self,
      from: JSONEncoder().encode(response)
    )
    XCTAssertEqual(decoded, response)
  }

  func testPermissionRemediationPayloadPreservesAuthorityBinding() throws {
    let response = IPCAgentPermissionRemediationResponse(
      taskID: "tsk-remediation",
      messageKey: "tool:command-1",
      installationID: "ainst-antigravity",
      candidateID: "candidate-1",
      action: "command",
      target: "swift test",
      displayRule: "command(swift test)",
      requiresConfirmation: false,
      settingsRevision: "revision-1"
    )

    let decoded = try JSONDecoder().decode(
      IPCAgentPermissionRemediationResponse.self,
      from: JSONEncoder().encode(response)
    )
    XCTAssertEqual(decoded, response)
  }

  func testNativePermissionErrorsUseStableCodes() {
    let expectations: [(AgentNativePermissionPolicyError, String, Bool)] = [
      (.unavailable, "agent_native_permissions_unavailable", false),
      (.revisionConflict, "agent_permission_revision_conflict", true),
      (.settingsInvalid, "agent_permission_settings_invalid", false),
      (.settingsUnsafe, "agent_permission_settings_unsafe", false),
      (.ruleInvalid, "agent_permission_rule_invalid", false),
      (.remediationUnavailable, "agent_permission_remediation_unavailable", false),
    ]

    for (source, code, retryable) in expectations {
      let mapped = BridgeServiceXPCController.map(source)
      XCTAssertEqual(mapped.code, code)
      XCTAssertEqual(mapped.retryable, retryable)
    }
  }

  func testOneTimeApprovalFieldsRemainOptionalAndRoundTrip() throws {
    let request = IPCApprovalResolutionRequest(
      taskID: "tsk-1",
      approvalID: "approval-1",
      decision: "allow",
      oneTimeToolAutoApproval: true
    )
    XCTAssertEqual(
      try JSONDecoder().decode(
        IPCApprovalResolutionRequest.self,
        from: JSONEncoder().encode(request)
      ),
      request
    )

    let legacy = Data(
      "{\"task_id\":\"tsk-1\",\"approval_id\":\"approval-1\",\"decision\":\"allow\"}".utf8
    )
    XCTAssertNil(
      try JSONDecoder().decode(IPCApprovalResolutionRequest.self, from: legacy)
        .oneTimeToolAutoApproval
    )
  }
}
