import BridgeAgentCore
import Foundation
import XCTest

@testable import BridgeServiceCore

final class ServiceAgentRegistryReplacementTests: XCTestCase {
  func testReplacementCanRecoverMissingOldArtifactAndPreservesInstallationID() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let oldExecutable = try makeExecutable(in: fixture.rootURL, named: "old-agent")
    let oldConfiguration = try makeFile(
      in: fixture.rootURL,
      named: "old-profile.yml",
      contents: "profile: old\n"
    )
    let registry = try makeRegistry(fixture: fixture)
    let original = try await registry.registerAndProbe(
      try request(executable: oldExecutable, configuration: oldConfiguration, enabled: true)
    )
    try FileManager.default.removeItem(atPath: oldConfiguration)

    let newExecutable = try makeExecutable(in: fixture.rootURL, named: "new-agent")
    let newConfiguration = try makeFile(
      in: fixture.rootURL,
      named: "new-profile.yml",
      contents: "profile: new\n"
    )
    let replaced = try await registry.replaceAndProbe(
      installationID: original.id,
      request: try request(
        executable: newExecutable,
        configuration: newConfiguration,
        enabled: false
      )
    )

    XCTAssertEqual(replaced.id, original.id)
    XCTAssertEqual(replaced.createdAt, original.createdAt)
    XCTAssertTrue(replaced.isEnabled)
    XCTAssertEqual(replaced.executablePath, newExecutable)
    XCTAssertEqual(replaced.artifacts.first?.canonicalPath, newConfiguration)
    let persisted = try await registry.installation(id: original.id)
    XCTAssertEqual(persisted, replaced)
  }

  func testReplacementPreservesInstallationIDWhenExecutablePathChanges() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let originalExecutable = try makeExecutable(in: fixture.rootURL, named: "original-agent")
    let registry = try makeRegistry(fixture: fixture)
    let original = try await registry.registerAndProbe(
      try request(executable: originalExecutable, configuration: nil, enabled: false)
    )
    let replacementExecutable = try makeExecutable(in: fixture.rootURL, named: "replacement-agent")

    let replaced = try await registry.replaceAndProbe(
      installationID: original.id,
      request: try request(executable: replacementExecutable, configuration: nil, enabled: true)
    )

    XCTAssertEqual(replaced.id, original.id)
    XCTAssertEqual(replaced.createdAt, original.createdAt)
    XCTAssertFalse(replaced.isEnabled)
    XCTAssertEqual(replaced.executablePath, replacementExecutable)
  }

  func testFailedReplacementLeavesOriginalRecordUntouched() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let originalExecutable = try makeExecutable(in: fixture.rootURL, named: "original-agent")
    let registry = try makeRegistry(fixture: fixture)
    let original = try await registry.registerAndProbe(
      try request(executable: originalExecutable, configuration: nil, enabled: true)
    )
    let rejectedExecutable = try makeExecutable(in: fixture.rootURL, named: "reject-agent")

    do {
      _ = try await registry.replaceAndProbe(
        installationID: original.id,
        request: try request(executable: rejectedExecutable, configuration: nil, enabled: false)
      )
      XCTFail("A failed replacement Probe must throw.")
    } catch let error as ServiceAgentRegistryError {
      XCTAssertEqual(error, .connectionProbeFailed(original.id))
    }

    let persisted = try await registry.installation(id: original.id)
    XCTAssertEqual(persisted, original)
  }

  private func makeRegistry(fixture: ServiceCoreFixture) throws -> ServiceAgentRegistry {
    ServiceAgentRegistry(
      store: try SimpleServiceStore(path: fixture.databasePath),
      providers: [try ReplacementFixtureProvider()],
      now: { Date(timeIntervalSince1970: 1_800_000_000) }
    )
  }

  private func request(
    executable: String,
    configuration: String?,
    enabled: Bool
  ) throws -> ServiceAgentRegistrationRequest {
    let artifacts: [ServiceAgentInstallationArtifactRequest]
    if let configuration {
      artifacts = [
        try ServiceAgentInstallationArtifactRequest(
          role: .launchConfiguration,
          path: configuration
        )
      ]
    } else {
      artifacts = []
    }
    return try ServiceAgentRegistrationRequest(
      providerID: .openCode,
      displayName: "OpenCode",
      executablePath: executable,
      trustProfile: .managed,
      securityProfileID: AgentProfileID(rawValue: "controlled-readonly"),
      enableOnSuccess: enabled,
      artifacts: artifacts
    )
  }

  private func makeExecutable(in directory: URL, named name: String) throws -> String {
    try makeFile(in: directory, named: name, contents: "#!/bin/sh\nexit 0\n", executable: true)
  }

  private func makeFile(
    in directory: URL,
    named name: String,
    contents: String,
    executable: Bool = false
  ) throws -> String {
    let url = directory.appendingPathComponent(name)
    try Data(contents.utf8).write(to: url)
    if executable {
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)],
        ofItemAtPath: url.path
      )
    }
    return url.path
  }
}

private struct ReplacementFixtureProvider: AgentProvider, Sendable {
  let descriptor: AgentProviderDescriptor

  init() throws {
    descriptor = try AgentProviderDescriptor(
      providerID: .openCode,
      displayName: "OpenCode",
      adapterRevision: 1
    )
  }

  func probe(_ request: AgentProbeRequest) async -> AgentProbeResult {
    if request.installation.executablePath.contains("reject-agent") {
      return AgentProbeResult(
        installation: request.installation,
        available: false,
        capabilities: .empty,
        unavailableReason: "The replacement fixture rejected the executable."
      )
    }
    guard
      let installation = try? AgentInstallation(
        id: request.installation.id,
        providerID: request.installation.providerID,
        executablePath: request.installation.executablePath,
        version: "2.0.0",
        protocolRevision: "1"
      )
    else {
      return AgentProbeResult(
        installation: request.installation,
        available: false,
        capabilities: .empty,
        unavailableReason: "The fixture installation is invalid."
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
    _ request: AgentExecutionRequest,
    installation: AgentInstallation
  ) async throws -> AgentExecutionHandle {
    throw AgentRuntimeError.processUnavailable
  }
}
