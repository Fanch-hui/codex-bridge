import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore
import Foundation
import XCTest

final class TaskHandoffSummaryTests: XCTestCase {
  func testCandidateListExcludesSourceProvider() {
    XCTAssertTrue(TaskHandoffSummary.providers(excluding: "codex", installations: []).isEmpty)
    XCTAssertEqual(
      TaskHandoffSummary.providers(excluding: "opencode", installations: []).map(\.id), ["codex"])
  }

  func testLegacyUnversionedSubmissionFailsClosed() {
    XCTAssertThrowsError(
      try WorkbenchHandoffClient.request(
        sourceTaskID: "source", providerID: "opencode", additionalInstructions: "legacy text",
        action: nil, handoffID: nil, revision: nil))
    XCTAssertThrowsError(
      try WorkbenchHandoffClient.request(
        sourceTaskID: "source", providerID: "opencode", additionalInstructions: "",
        action: "submit", handoffID: "transfer-one", revision: nil))
  }

  func testPrepareAcceptsEmptySupplementAndSubmitUsesExactRevision() throws {
    let prepare = try WorkbenchHandoffClient.request(
      sourceTaskID: "source", providerID: "opencode", additionalInstructions: "",
      action: "prepare", handoffID: "transfer-one", revision: nil)
    XCTAssertEqual(prepare.action, .prepare)
    let submit = try WorkbenchHandoffClient.request(
      sourceTaskID: "source", providerID: "opencode", additionalInstructions: "",
      action: "submit", handoffID: prepare.handoffID, revision: "frozen-hash")
    XCTAssertEqual(submit.handoffID, prepare.handoffID)
    XCTAssertEqual(submit.expectedRevision, "frozen-hash")
    let restored = try JSONDecoder().decode(
      MCPTaskHandoffRequest.self, from: JSONEncoder().encode(submit))
    XCTAssertEqual(restored, submit)
  }

  func testStatusRecoveryDoesNotNeedPlaintextDraftOrSourceSessionFormat() throws {
    let request = try WorkbenchHandoffClient.request(
      sourceTaskID: "source", providerID: "antigravity", additionalInstructions: "",
      action: "status", handoffID: "transfer-one", revision: nil)
    XCTAssertEqual(request.action, .status)
    XCTAssertTrue(request.additionalInstructions.isEmpty)
    let preview = MCPTaskHandoffPreview(
      handoffID: "transfer-one", sourceTaskID: "source", providerID: "antigravity",
      model: "selected-model", permissionMode: "read-only", networkAllowed: false,
      revision: "frozen-hash", prompt: "中文\n```json\n{}\n```", additionalInstructions: "",
      warnings: ["Context capacity is unknown"], ready: false, estimatedTokens: 100,
      phase: "running", targetTaskID: "target-one")
    let restored = try JSONDecoder().decode(
      MCPTaskHandoffPreview.self, from: JSONEncoder().encode(preview))
    XCTAssertEqual(restored, preview)
    XCTAssertNil(restored.contextWindowTokens)
  }
}
