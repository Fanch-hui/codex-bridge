import BridgeAgentCore
import Darwin
import Foundation
import XCTest

@testable import BridgeServiceCore

final class ServiceAgentNativePermissionRegistryTests: XCTestCase {
  func testRegistryValidatesInstallationAndRoutesSnapshotAndMutation() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "bridge-native-permission-registry-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let executable = root.appending(path: "agy")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    XCTAssertEqual(chmod(executable.path, 0o700), 0)

    let manager = try NativePermissionFixtureManager()
    let provider = try NativePermissionFixtureProvider(manager: manager)
    let registry = ServiceAgentRegistry(
      store: try SimpleServiceStore(path: root.appending(path: "service.sqlite").path),
      providers: [provider],
      makeInstallationID: { AgentInstallationID(rawValue: "ainst-native-permissions") }
    )
    let record = try await registry.registerAndProbe(
      ServiceAgentRegistrationRequest(
        providerID: .antigravity,
        displayName: "Antigravity",
        executablePath: executable.path,
        trustProfile: .managed,
        enableOnSuccess: true
      )
    )

    let original = try await registry.nativePermissionPolicy(installationID: record.id)
    XCTAssertEqual(original.installationID, record.id)
    XCTAssertEqual(original.toolPermission, "proceed-in-sandbox")

    let updated = try await registry.updateNativePermissionPolicy(
      installationID: record.id,
      mutation: .setToolPermission("strict"),
      expectedRevision: original.revision
    )
    XCTAssertEqual(updated.toolPermission, "strict")
    let invocation = await manager.lastInvocation()
    XCTAssertEqual(invocation?.installationID, record.id)
    XCTAssertEqual(invocation?.mutation, .setToolPermission("strict"))
    XCTAssertEqual(invocation?.expectedRevision, "revision-1")
  }

  func testRegistryRejectsProviderWithoutNativePermissionManager() async throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "bridge-native-permission-unavailable-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let executable = root.appending(path: "provider")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    XCTAssertEqual(chmod(executable.path, 0o700), 0)

    let provider = try NativePermissionFixtureProvider(manager: nil)
    let registry = ServiceAgentRegistry(
      store: try SimpleServiceStore(path: root.appending(path: "service.sqlite").path),
      providers: [provider],
      makeInstallationID: { AgentInstallationID(rawValue: "ainst-no-native-permissions") }
    )
    let record = try await registry.registerAndProbe(
      ServiceAgentRegistrationRequest(
        providerID: .antigravity,
        displayName: "No permissions",
        executablePath: executable.path,
        trustProfile: .managed,
        enableOnSuccess: true
      )
    )

    do {
      _ = try await registry.nativePermissionPolicy(installationID: record.id)
      XCTFail("A provider without a native permission manager must fail closed.")
    } catch let error as AgentNativePermissionPolicyError {
      XCTAssertEqual(error, .unavailable)
    }
  }
}

private actor NativePermissionFixtureManager: AgentNativePermissionPolicyManaging {
  struct Invocation: Equatable, Sendable {
    let installationID: AgentInstallationID
    let mutation: AgentNativePermissionMutation
    let expectedRevision: String?
  }

  private var toolPermission = "proceed-in-sandbox"
  private var invocation: Invocation?
  private let modes: [AgentNativePermissionModeDescriptor]

  init() throws {
    modes = [
      try AgentNativePermissionModeDescriptor(
        id: "proceed-in-sandbox",
        displayName: "Proceed in sandbox"
      ),
      try AgentNativePermissionModeDescriptor(id: "strict", displayName: "Strict"),
    ]
  }

  func snapshot(
    installation: AgentInstallation
  ) async throws -> AgentNativePermissionPolicySnapshot {
    try makeSnapshot(installation: installation, revision: "revision-1")
  }

  func update(
    installation: AgentInstallation,
    mutation: AgentNativePermissionMutation,
    expectedRevision: String?
  ) async throws -> AgentNativePermissionPolicySnapshot {
    invocation = Invocation(
      installationID: installation.id,
      mutation: mutation,
      expectedRevision: expectedRevision
    )
    guard case .setToolPermission(let value) = mutation else {
      throw AgentNativePermissionPolicyError.ruleInvalid
    }
    toolPermission = value
    return try makeSnapshot(installation: installation, revision: "revision-2")
  }

  func lastInvocation() -> Invocation? {
    invocation
  }

  private func makeSnapshot(
    installation: AgentInstallation,
    revision: String
  ) throws -> AgentNativePermissionPolicySnapshot {
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

private struct NativePermissionFixtureProvider: AgentProvider, Sendable {
  let descriptor: AgentProviderDescriptor
  let manager: NativePermissionFixtureManager?

  init(manager: NativePermissionFixtureManager?) throws {
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
    guard
      let installation = try? AgentInstallation(
        id: request.installation.id,
        providerID: request.installation.providerID,
        executablePath: request.installation.executablePath,
        version: "1.1.24",
        protocolRevision: "stream-json-v1"
      )
    else {
      return AgentProbeResult(
        installation: request.installation,
        available: false,
        capabilities: .empty,
        unavailableReason: "Invalid fixture installation."
      )
    }
    let capabilities: Set<AgentCapability> = [.sessionCreate, .textDelta, .workspaceRead]
    return AgentProbeResult(
      installation: installation,
      available: true,
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
