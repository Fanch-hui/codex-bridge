import BridgeAgentCore
import Foundation
import XCTest

@testable import BridgeServiceCore

extension ServiceAgentRegistryStabilityTests {
  func testContentUpdateAutomaticallyProbesAndPreservesConnection() async throws {
    let fixture = try StabilityFixture()
    defer { fixture.remove() }
    let executable = try makeExecutable(in: fixture.rootURL, named: "updated-agent")
    let state = StabilityProbeState()
    let first = try makeRegistry(fixture: fixture, state: state, adapterRevision: 1)
    let registered = try await first.registerAndProbe(
      request(executable: executable, enabled: true))
    try replaceExecutableContents(at: executable, with: "#!/bin/sh\necho updated\n")
    let upgraded = try makeRegistry(fixture: fixture, state: state, adapterRevision: 2)

    let refreshed = try await upgraded.refreshInstallationStates()
    let connected = try XCTUnwrap(refreshed.first)
    XCTAssertEqual(connected.id, registered.id)
    XCTAssertTrue(connected.isSelectable)
    XCTAssertEqual(connected.adapterRevision, 2)
    XCTAssertNotEqual(connected.executableIdentity.sha256, registered.executableIdentity.sha256)
    let validated = try await upgraded.validateForExecution(installationID: registered.id)
    XCTAssertEqual(validated, connected)
    let count = await state.probeCount()
    XCTAssertEqual(count, 2)
  }

  func testIncompatibleUpdateRemainsEnabledButCannotExecuteOrRepeatedlyProbe() async throws {
    let fixture = try StabilityFixture()
    defer { fixture.remove() }
    let executable = try makeExecutable(in: fixture.rootURL, named: "incompatible-agent")
    let state = StabilityProbeState()
    let registry = try makeRegistry(fixture: fixture, state: state, adapterRevision: 1)
    let original = try await registry.registerAndProbe(
      request(executable: executable, enabled: true))
    try replaceExecutableContents(at: executable, with: "#!/bin/sh\necho incompatible\n")
    await state.setOutcome(.unavailable("Required protocol method is missing."))

    let refreshed = try await registry.refreshInstallationStates()
    let blocked = try XCTUnwrap(refreshed.first)
    XCTAssertTrue(blocked.isEnabled)
    XCTAssertFalse(blocked.isSelectable)
    XCTAssertEqual(blocked.availability, .unavailable)
    XCTAssertEqual(blocked.executableIdentity, original.executableIdentity)
    XCTAssertEqual(blocked.lastProbeError, "Required protocol method is missing.")
    do {
      _ = try await registry.validateForExecution(installationID: original.id)
      XCTFail("An incompatible update cannot execute.")
    } catch let error as ServiceAgentRegistryError {
      XCTAssertEqual(error, .installationUnavailable(original.id))
    }
    let count = await state.probeCount()
    XCTAssertEqual(count, 2)
  }

  func testDisabledInstallationUpdateDoesNotReconnect() async throws {
    let fixture = try StabilityFixture()
    defer { fixture.remove() }
    let executable = try makeExecutable(in: fixture.rootURL, named: "disabled-updated-agent")
    let state = StabilityProbeState()
    let registry = try makeRegistry(fixture: fixture, state: state, adapterRevision: 1)
    let original = try await registry.registerAndProbe(
      request(executable: executable, enabled: false))
    try replaceExecutableContents(at: executable, with: "#!/bin/sh\necho updated\n")
    let refreshed = try await registry.refreshInstallationStates()
    XCTAssertFalse(try XCTUnwrap(refreshed.first).isEnabled)
    XCTAssertEqual(refreshed.first?.executableIdentity, original.executableIdentity)
    let count = await state.probeCount()
    XCTAssertEqual(count, 1)
  }

  func testUpdateResolverMovesInstallationAfterSuccessfulProbe() async throws {
    let fixture = try StabilityFixture()
    defer { fixture.remove() }
    let originalPath = try makeExecutable(in: fixture.rootURL, named: "agent-v1")
    let updatedPath = try makeExecutable(in: fixture.rootURL, named: "agent-v2")
    let state = StabilityProbeState()
    let store = try SimpleServiceStore(path: fixture.databasePath)
    let replacement = try request(executable: updatedPath, enabled: true)
    let registry = ServiceAgentRegistry(
      store: store, providers: [try StabilityFixtureProvider(state: state, adapterRevision: 1)],
      resolveUpdatedInstallation: { _ in replacement }
    )
    let original = try await registry.registerAndProbe(
      request(executable: originalPath, enabled: true))
    try FileManager.default.removeItem(atPath: originalPath)
    let refreshed = try await registry.refreshInstallationStates()
    let connected = try XCTUnwrap(refreshed.first)
    XCTAssertEqual(connected.id, original.id)
    XCTAssertTrue(connected.isSelectable)
    XCTAssertEqual(connected.executablePath, updatedPath)
    let stored = try await store.agentInstallation(id: original.id)
    XCTAssertEqual(stored, connected)
  }

  func testRuntimeArtifactUpdateIsReprobedAutomatically() async throws {
    let fixture = try StabilityFixture()
    defer { fixture.remove() }
    let executable = try makeExecutable(in: fixture.rootURL, named: "runtime-agent")
    let manifest = try makeConfiguration(in: fixture.rootURL, named: "package.json")
    let state = StabilityProbeState()
    let registry = try makeRegistry(fixture: fixture, state: state, adapterRevision: 1)
    let registration = try ServiceAgentRegistrationRequest(
      providerID: .openCode, displayName: "Runtime Fixture", executablePath: executable,
      trustProfile: .managed, enableOnSuccess: true,
      artifacts: [
        try ServiceAgentInstallationArtifactRequest(role: .runtimeManifest, path: manifest)
      ]
    )
    let original = try await registry.registerAndProbe(registration)
    try Data("version: updated\n".utf8).write(to: URL(fileURLWithPath: manifest))
    let refreshed = try await registry.refreshInstallationStates()
    let connected = try XCTUnwrap(refreshed.first)
    XCTAssertTrue(connected.isSelectable)
    XCTAssertNotEqual(
      connected.artifacts.first?.identity.sha256, original.artifacts.first?.identity.sha256)
    let count = await state.probeCount()
    XCTAssertEqual(count, 2)
  }
}
