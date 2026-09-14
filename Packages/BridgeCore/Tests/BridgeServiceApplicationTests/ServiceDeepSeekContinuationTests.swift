import BridgeAgentCore
import BridgeCodexService
import BridgeDomain
import BridgeMCP
import BridgeServiceApplication
import BridgeServiceCore
import Foundation
import XCTest

final class ServiceDeepSeekContinuationTests: XCTestCase {
  func testCompletedSessionContinuationPersistsExactBinding() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let provider = try DeepSeekPolicyFixtureProvider(supportsContinuation: true)
    let executable = fixture.root.appendingPathComponent("dsh")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let artifacts = try AgentInstallationArtifactRole.allCases.map { role in
      let path = fixture.root.appendingPathComponent(role.rawValue)
      try Data("fixture".utf8).write(to: path)
      if role.requiresExecutable {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
      }
      return try ServiceAgentInstallationArtifactRequest(role: role, path: path.path)
    }
    let registry = ServiceAgentRegistry(store: fixture.store, providers: [provider])
    let installation = try await registry.registerAndProbe(
      .init(
        providerID: .deepSeekHarness, displayName: "DSH", executablePath: executable.path,
        trustProfile: .userTrusted,
        securityProfileID: ServiceAgentProviderPolicyRegistry.controlledReadOnlyProfileID,
        enableOnSuccess: true, artifacts: artifacts
      ))
    let firstID = TaskID(rawValue: "first-dsh")
    _ = try await fixture.tasks.submit(
      .init(
        projectID: fixture.project.id, source: .macOSApp, prompt: "First instruction",
        providerID: "deepseek-harness", installationID: installation.id.rawValue,
        selectionMode: .explicit, executionModel: "deepseek-v4-pro", executionEffort: "high",
        permissionMode: .readOnly
      ), taskID: firstID)
    _ = try await fixture.tasks.approveAndBegin(taskID: firstID)
    _ = try await fixture.tasks.markAgentExecutionStarted(
      taskID: firstID, providerSessionID: "saved-session", providerRunID: "first-run"
    )
    _ = try await fixture.tasks.complete(taskID: firstID, resultSummary: "Done", changedFiles: [])
    let application = makeServiceApplication(
      fixture: fixture, catalogScript: serviceModelCatalogScript, agentRegistry: registry
    )
    let receipt = try await application.serviceSubmitTask(
      .init(
        projectID: fixture.project.id.rawValue, prompt: "Next instruction",
        threadID: "saved-session",
        providerID: "deepseek-harness", installationID: installation.id.rawValue,
        permissionMode: "read-only", permissionModeOverride: true, clientRequestID: "dsh-continue"
      ), deadline: .now.advanced(by: .seconds(10)))
    let resumed = try await fixture.tasks.task(id: TaskID(rawValue: receipt.taskID))
    XCTAssertEqual(resumed?.requestedThreadID, "saved-session")
    XCTAssertEqual(resumed?.installationID, installation.id.rawValue)
    XCTAssertEqual(resumed?.projectID, fixture.project.id)
  }
}
