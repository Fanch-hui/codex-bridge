import BridgeAgentCore
import BridgeDomain
import BridgeServiceApplication
import BridgeServiceCore
import Darwin
import Foundation
import XCTest

final class AgentPermissionRemediationTests: XCTestCase {
  func testApplyRecomputesDeclinedToolAndWritesAllowRule() async throws {
    let context = try await makeContext()
    let remediation = try await context.application.serviceAgentPermissionRemediation(
      taskID: context.taskID,
      messageKey: "tool:command-1",
      deadline: .now.advanced(by: .seconds(3))
    )

    XCTAssertEqual(remediation.candidate.action, "command")
    XCTAssertEqual(remediation.candidate.target, "swift test")
    let snapshot = try await context.application.serviceApplyAgentPermissionRemediation(
      taskID: context.taskID,
      messageKey: remediation.messageKey,
      candidateID: remediation.candidate.candidateID,
      expectedRevision: remediation.settingsRevision,
      deadline: .now.advanced(by: .seconds(3))
    )

    XCTAssertEqual(snapshot.revision, "revision-2")
    let mutation = await context.manager.lastMutation()
    XCTAssertEqual(mutation, .addRule(effect: .allow, action: "command", target: "swift test"))
  }

  func testApplyRejectsCandidateWhenAuthoritativeMessageChanged() async throws {
    let context = try await makeContext()
    let remediation = try await context.application.serviceAgentPermissionRemediation(
      taskID: context.taskID,
      messageKey: "tool:command-1",
      deadline: .now.advanced(by: .seconds(3))
    )
    try await context.fixture.tasks.upsertTaskMessage(
      taskID: context.taskID,
      key: remediation.messageKey,
      role: .agent,
      content: "permission denied",
      kind: .toolCall,
      toolName: "run_command",
      toolStatus: "declined",
      toolArguments: #"{"command":"swift build"}"#
    )

    do {
      _ = try await context.application.serviceApplyAgentPermissionRemediation(
        taskID: context.taskID,
        messageKey: remediation.messageKey,
        candidateID: remediation.candidate.candidateID,
        expectedRevision: remediation.settingsRevision,
        deadline: .now.advanced(by: .seconds(3))
      )
      XCTFail("A stale candidate must be rejected.")
    } catch {
      XCTAssertEqual(error as? AgentNativePermissionPolicyError, .remediationUnavailable)
    }
    let mutation = await context.manager.lastMutation()
    XCTAssertNil(mutation)
  }

  func testRemediationRejectsForgedMessageKey() async throws {
    let context = try await makeContext()

    do {
      _ = try await context.application.serviceAgentPermissionRemediation(
        taskID: context.taskID,
        messageKey: "tool:not-present",
        deadline: .now.advanced(by: .seconds(3))
      )
      XCTFail("A forged message key must be rejected.")
    } catch {
      XCTAssertEqual(error as? AgentNativePermissionPolicyError, .remediationUnavailable)
    }
  }

  private func makeContext() async throws -> RemediationTestContext {
    let fixture = try await makeServiceApplicationFixture(self)
    let executable = fixture.root.appending(path: "agy")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    XCTAssertEqual(chmod(executable.path, 0o700), 0)

    let manager = try RemediationFixtureManager()
    let provider = try RemediationFixtureProvider(manager: manager)
    let registry = ServiceAgentRegistry(
      store: fixture.store,
      providers: [provider],
      makeInstallationID: { AgentInstallationID(rawValue: "ainst-remediation") }
    )
    let installation = try await registry.registerAndProbe(
      ServiceAgentRegistrationRequest(
        providerID: .antigravity,
        displayName: "Antigravity",
        executablePath: executable.path,
        trustProfile: .managed,
        enableOnSuccess: true
      )
    )
    let task = try await fixture.tasks.submit(
      ServiceTaskRequest(
        projectID: fixture.project.id,
        source: .macOSApp,
        prompt: "Run the tests.",
        providerID: AgentProviderID.antigravity.rawValue,
        installationID: installation.id.rawValue,
        selectionMode: .explicit,
        executionModel: serviceDefaultProviderExecutionModel,
        executionEffort: serviceDefaultProviderExecutionEffort,
        permissionMode: .readOnly
      )
    ).task
    _ = try await fixture.tasks.approveAndBegin(taskID: task.id)
    try await fixture.tasks.upsertTaskMessage(
      taskID: task.id,
      key: "tool:command-1",
      role: .agent,
      content: "permission denied",
      kind: .toolCall,
      toolName: "run_command",
      toolStatus: "declined",
      toolArguments: #"{"command":"swift test"}"#
    )
    _ = try await fixture.tasks.fail(
      taskID: task.id,
      failureCode: "antigravity_permission_denied",
      summary: "AGY denied the tool."
    )
    return RemediationTestContext(
      fixture: fixture,
      application: makeServiceApplication(
        fixture: fixture,
        catalogScript: serviceModelCatalogScript,
        agentRegistry: registry
      ),
      manager: manager,
      taskID: task.id
    )
  }
}

private struct RemediationTestContext {
  let fixture: ServiceApplicationFixture
  let application: BridgeServiceApplication
  let manager: RemediationFixtureManager
  let taskID: TaskID
}

private actor RemediationFixtureManager: AgentNativePermissionPolicyManaging {
  private var revision = "revision-1"
  private var mutation: AgentNativePermissionMutation?
  private let mode: AgentNativePermissionModeDescriptor

  init() throws {
    mode = try AgentNativePermissionModeDescriptor(
      id: "proceed-in-sandbox",
      displayName: "Proceed in sandbox"
    )
  }

  func snapshot(installation: AgentInstallation) async throws
    -> AgentNativePermissionPolicySnapshot
  {
    try snapshotValue(installation: installation)
  }

  func update(
    installation: AgentInstallation,
    mutation: AgentNativePermissionMutation,
    expectedRevision: String?
  ) async throws -> AgentNativePermissionPolicySnapshot {
    guard expectedRevision == revision else {
      throw AgentNativePermissionPolicyError.revisionConflict
    }
    self.mutation = mutation
    revision = "revision-2"
    return try snapshotValue(installation: installation)
  }

  func remediation(
    toolName: String,
    toolArguments: String
  ) async -> AgentNativePermissionRemediation? {
    guard toolName == "run_command",
      let data = toolArguments.data(using: .utf8),
      let decoded = try? JSONSerialization.jsonObject(with: data),
      let object = decoded as? [String: String],
      let command = object["command"]
    else { return nil }
    return try? AgentNativePermissionRemediation(
      candidateID: "candidate-\(command.replacingOccurrences(of: " ", with: "-"))",
      action: "command",
      target: command,
      displayRule: "command(\(command))",
      requiresConfirmation: false
    )
  }

  func lastMutation() -> AgentNativePermissionMutation? {
    mutation
  }

  private func snapshotValue(
    installation: AgentInstallation
  ) throws -> AgentNativePermissionPolicySnapshot {
    try AgentNativePermissionPolicySnapshot(
      providerID: installation.providerID,
      installationID: installation.id,
      toolPermission: mode.id,
      availableModes: [mode],
      availableActions: ["command"],
      rules: [],
      revision: revision
    )
  }
}

private struct RemediationFixtureProvider: AgentProvider, Sendable {
  let descriptor: AgentProviderDescriptor
  let manager: RemediationFixtureManager

  init(manager: RemediationFixtureManager) throws {
    descriptor = try AgentProviderDescriptor(
      providerID: .antigravity,
      displayName: "Antigravity fixture",
      adapterRevision: 1
    )
    self.manager = manager
  }

  var nativePermissionPolicyManager: (any AgentNativePermissionPolicyManaging)? {
    manager
  }

  func probe(_ request: AgentProbeRequest) async -> AgentProbeResult {
    let installation = try? AgentInstallation(
      id: request.installation.id,
      providerID: request.installation.providerID,
      executablePath: request.installation.executablePath,
      version: "1.1.24",
      protocolRevision: "stream-json-v1"
    )
    let capabilities: Set<AgentCapability> = [.sessionCreate, .workspaceRead]
    return AgentProbeResult(
      installation: installation ?? request.installation,
      available: installation != nil,
      capabilities: AgentCapabilitySnapshot(
        advertised: capabilities,
        observed: capabilities,
        enforced: capabilities
      )
    )
  }

  func start(
    _: AgentExecutionRequest,
    installation _: AgentInstallation
  ) async throws -> AgentExecutionHandle {
    throw AgentRuntimeError.processUnavailable
  }
}
