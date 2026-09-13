import BridgeAgentCore
import BridgeServiceApplication
import BridgeServiceCore
import Foundation
import XCTest

final class ServiceAgentHeadlessPermissionTests: XCTestCase {
  func testAntigravityConnectionRequiresConsentAndEnablesAlwaysProceed() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let executable = fixture.root.appending(path: "agy")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    let permissions = try HeadlessPermissionFixtureManager()
    let provider = try HeadlessPermissionFixtureProvider(manager: permissions)
    let registry = ServiceAgentRegistry(
      store: fixture.store,
      providers: [provider],
      makeInstallationID: { AgentInstallationID(rawValue: "ainst-headless") }
    )
    let request = try ServiceAgentRegistrationRequest(
      providerID: .antigravity,
      displayName: "Antigravity",
      executablePath: executable.path,
      trustProfile: .userTrusted,
      securityProfileID: AgentProfileID(rawValue: "desktop-shared")
    )
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry
    )

    do {
      _ = try await application.serviceConnectManagedAgent(
        providerID: .antigravity,
        baseURL: nil,
        apiKey: nil,
        candidates: [request],
        deadline: .now.advanced(by: .seconds(3))
      )
      XCTFail("AGY connection must require explicit consent.")
    } catch let error as ServiceAgentConnectionError {
      XCTAssertEqual(error, .headlessPermissionConfirmationRequired)
    }
    let unregistered = try await registry.installations()
    XCTAssertTrue(unregistered.isEmpty)
    let rejectedUpdateCount = await permissions.updateCount()
    XCTAssertEqual(rejectedUpdateCount, 0)

    let connected = try await application.serviceConnectManagedAgent(
      providerID: .antigravity,
      baseURL: nil,
      apiKey: nil,
      candidates: [request],
      alwaysProceedConfirmed: true,
      deadline: .now.advanced(by: .seconds(3))
    )
    XCTAssertTrue(connected.isSelectable)
    let permission = await permissions.toolPermissionValue()
    let updateCount = await permissions.updateCount()
    XCTAssertEqual(permission, "always-proceed")
    XCTAssertEqual(updateCount, 1)
  }

  func testPermissionSetupFailureLeavesConnectionDisabled() async throws {
    let fixture = try await makeServiceApplicationFixture(self)
    let executable = fixture.root.appending(path: "agy")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let permissions = try HeadlessPermissionFixtureManager()
    await permissions.setUpdateFailure(true)
    let provider = try HeadlessPermissionFixtureProvider(manager: permissions)
    let registry = ServiceAgentRegistry(
      store: fixture.store,
      providers: [provider],
      makeInstallationID: { AgentInstallationID(rawValue: "ainst-headless-failure") }
    )
    let request = try ServiceAgentRegistrationRequest(
      providerID: .antigravity,
      displayName: "Antigravity",
      executablePath: executable.path,
      trustProfile: .userTrusted,
      securityProfileID: AgentProfileID(rawValue: "desktop-shared")
    )
    let application = makeServiceApplication(
      fixture: fixture,
      catalogScript: serviceModelCatalogScript,
      agentRegistry: registry
    )

    do {
      _ = try await application.serviceConnectManagedAgent(
        providerID: .antigravity,
        baseURL: nil,
        apiKey: nil,
        candidates: [request],
        alwaysProceedConfirmed: true,
        deadline: .now.advanced(by: .seconds(3))
      )
      XCTFail("A failed permission setup must fail the connection.")
    } catch let error as AgentNativePermissionPolicyError {
      XCTAssertEqual(error, .settingsUnsafe)
    }
    let installations = try await registry.installations()
    XCTAssertEqual(installations.count, 1)
    XCTAssertFalse(try XCTUnwrap(installations.first).isEnabled)
  }
}

private actor HeadlessPermissionFixtureManager: AgentNativePermissionPolicyManaging {
  private var toolPermission = "request-review"
  private var updates = 0
  private var revision = "revision-1"
  private var shouldFailUpdate = false
  private let modes: [AgentNativePermissionModeDescriptor]

  init() throws {
    modes = try [
      AgentNativePermissionModeDescriptor(id: "request-review", displayName: "Request review"),
      AgentNativePermissionModeDescriptor(
        id: "always-proceed",
        displayName: "Always Proceed",
        requiresConfirmation: true
      ),
    ]
  }

  func snapshot(installation: AgentInstallation) async throws
    -> AgentNativePermissionPolicySnapshot
  {
    try makeSnapshot(installation: installation)
  }

  func update(
    installation: AgentInstallation,
    mutation: AgentNativePermissionMutation,
    expectedRevision: String?
  ) async throws -> AgentNativePermissionPolicySnapshot {
    if shouldFailUpdate {
      throw AgentNativePermissionPolicyError.settingsUnsafe
    }
    guard expectedRevision == revision else {
      throw AgentNativePermissionPolicyError.revisionConflict
    }
    guard mutation == .setToolPermission("always-proceed") else {
      throw AgentNativePermissionPolicyError.ruleInvalid
    }
    toolPermission = "always-proceed"
    revision = "revision-2"
    updates += 1
    return try makeSnapshot(installation: installation)
  }

  func remediation(toolName _: String, toolArguments _: String)
    async -> AgentNativePermissionRemediation?
  {
    nil
  }

  func toolPermissionValue() -> String { toolPermission }

  func updateCount() -> Int { updates }

  func setUpdateFailure(_ value: Bool) { shouldFailUpdate = value }

  private func makeSnapshot(installation: AgentInstallation) throws
    -> AgentNativePermissionPolicySnapshot
  {
    try AgentNativePermissionPolicySnapshot(
      providerID: installation.providerID,
      installationID: installation.id,
      toolPermission: toolPermission,
      availableModes: modes,
      availableActions: ["command"],
      rules: [],
      revision: revision
    )
  }
}

private struct HeadlessPermissionFixtureProvider: AgentProvider, Sendable {
  let descriptor: AgentProviderDescriptor
  let nativePermissionPolicyManager: (any AgentNativePermissionPolicyManaging)?

  init(manager: HeadlessPermissionFixtureManager) throws {
    descriptor = try AgentProviderDescriptor(
      providerID: .antigravity,
      displayName: "Antigravity fixture",
      adapterRevision: 1
    )
    nativePermissionPolicyManager = manager
  }

  func probe(_ request: AgentProbeRequest) async -> AgentProbeResult {
    let installation = try? AgentInstallation(
      id: request.installation.id,
      providerID: request.installation.providerID,
      executablePath: request.installation.executablePath,
      version: "1.2.0",
      protocolRevision: "1"
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
