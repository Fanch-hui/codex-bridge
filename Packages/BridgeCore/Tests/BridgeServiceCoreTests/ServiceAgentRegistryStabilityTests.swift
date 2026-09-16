import BridgeAgentCore
import Foundation
import XCTest

@testable import BridgeServiceCore

final class ServiceAgentRegistryStabilityTests: XCTestCase {
  func testAdapterRevisionRefreshProbesAndPreservesEnabledRecord() async throws {
    let fixture = try StabilityFixture()
    defer { fixture.remove() }
    let executable = try makeExecutable(in: fixture.rootURL, named: "adapter-agent")
    let state = StabilityProbeState()
    let first = try makeRegistry(fixture: fixture, state: state, adapterRevision: 1)
    let registered = try await first.registerAndProbe(
      request(executable: executable, enabled: true)
    )
    let upgraded = try makeRegistry(fixture: fixture, state: state, adapterRevision: 2)

    let refreshed = try await upgraded.refreshInstallationStates()
    let record = try XCTUnwrap(refreshed.first)
    XCTAssertEqual(record.adapterRevision, 2)
    XCTAssertEqual(record.availability, .available)
    XCTAssertTrue(record.isEnabled)
    XCTAssertTrue(record.capabilities.effective.contains(.sessionCreate))
    let probeCountAfterRefresh = await state.probeCount()
    XCTAssertEqual(probeCountAfterRefresh, 2)

    let validated = try await upgraded.validateForExecution(installationID: registered.id)
    XCTAssertEqual(validated, record)
    let models = try await upgraded.models(installationID: registered.id)
    XCTAssertEqual(models.map(\.id), ["fixture-model"])
    let disabled = try await upgraded.setEnabled(false, installationID: registered.id)
    XCTAssertFalse(disabled.isEnabled)
    let enabled = try await upgraded.setEnabled(true, installationID: registered.id)
    XCTAssertTrue(enabled.isSelectable)
    let finalProbeCount = await state.probeCount()
    XCTAssertEqual(finalProbeCount, 2)
  }

  func testAdapterRevisionProbeFailureIsPersistedWithoutRepeatedProbe() async throws {
    let fixture = try StabilityFixture()
    defer { fixture.remove() }
    let executable = try makeExecutable(in: fixture.rootURL, named: "failed-adapter-agent")
    let state = StabilityProbeState()
    let first = try makeRegistry(fixture: fixture, state: state, adapterRevision: 1)
    let registered = try await first.registerAndProbe(
      request(executable: executable, enabled: true)
    )
    await state.setOutcome(.unavailable("The fixture adapter is unavailable."))
    let upgraded = try makeRegistry(fixture: fixture, state: state, adapterRevision: 2)

    let firstRefresh = try await upgraded.refreshInstallationStates()
    let unavailable = try XCTUnwrap(firstRefresh.first)
    XCTAssertEqual(unavailable.availability, .unavailable)
    XCTAssertTrue(unavailable.isEnabled)
    XCTAssertEqual(unavailable.lastProbeError, "The fixture adapter is unavailable.")
    let probeCountAfterFailure = await state.probeCount()
    XCTAssertEqual(probeCountAfterFailure, 2)

    let secondRefresh = try await upgraded.refreshInstallationStates()
    XCTAssertEqual(secondRefresh.first, unavailable)
    do {
      _ = try await upgraded.validateForExecution(installationID: registered.id)
      XCTFail("An unavailable installation must not validate for execution.")
    } catch let error as ServiceAgentRegistryError {
      XCTAssertEqual(error, .installationUnavailable(registered.id))
    }
    let finalProbeCount = await state.probeCount()
    XCTAssertEqual(finalProbeCount, 2)
  }

  func testMetadataOnlyChangesProbeAndPersistExecutableAndArtifactSnapshots() async throws {
    let fixture = try StabilityFixture()
    defer { fixture.remove() }
    let executable = try makeExecutable(in: fixture.rootURL, named: "metadata-agent")
    let configuration = try makeConfiguration(in: fixture.rootURL, named: "metadata.yml")
    let state = StabilityProbeState()
    let registry = try makeRegistry(fixture: fixture, state: state, adapterRevision: 1)
    let registered = try await registry.registerAndProbe(
      request(executable: executable, configuration: configuration, enabled: true)
    )
    let originalArtifact = try XCTUnwrap(registered.artifacts.first)

    try touch(executable, at: Date(timeIntervalSince1970: 1_900_000_000))
    try touch(configuration, at: Date(timeIntervalSince1970: 1_900_000_000))
    let reprobed = try await registry.reprobe(installationID: registered.id)
    XCTAssertEqual(reprobed.availability, .available)
    XCTAssertEqual(reprobed.executableIdentity.sha256, registered.executableIdentity.sha256)
    XCTAssertNotEqual(
      reprobed.executableIdentity.modificationTimeNanoseconds,
      registered.executableIdentity.modificationTimeNanoseconds
    )
    let reprobedArtifact = try XCTUnwrap(reprobed.artifacts.first)
    XCTAssertEqual(reprobedArtifact.identity.sha256, originalArtifact.identity.sha256)
    XCTAssertNotEqual(
      reprobedArtifact.identity.modificationTimeNanoseconds,
      originalArtifact.identity.modificationTimeNanoseconds
    )
    let reprobeCount = await state.probeCount()
    XCTAssertEqual(reprobeCount, 2)

    try touch(executable, at: Date(timeIntervalSince1970: 1_900_000_100))
    try touch(configuration, at: Date(timeIntervalSince1970: 1_900_000_100))
    let refreshed = try await registry.refreshInstallationStates()
    let current = try XCTUnwrap(refreshed.first)
    XCTAssertEqual(current.availability, .available)
    XCTAssertTrue(current.isSelectable)
    let refreshCount = await state.probeCount()
    XCTAssertEqual(refreshCount, 3)
    let persisted = try await registry.installation(id: registered.id)
    XCTAssertEqual(persisted, current)
  }

  func testContentChangeBlocksAdapterUpgradeWithoutExecutingProvider() async throws {
    let fixture = try StabilityFixture()
    defer { fixture.remove() }
    let executable = try makeExecutable(
      in: fixture.rootURL,
      named: "changed-agent",
      contents: "#!/bin/sh\necho original\n"
    )
    let state = StabilityProbeState()
    let first = try makeRegistry(fixture: fixture, state: state, adapterRevision: 1)
    let registered = try await first.registerAndProbe(
      request(executable: executable, enabled: true)
    )
    try replaceExecutableContents(at: executable, with: "#!/bin/sh\necho replaced\n")
    let upgraded = try makeRegistry(fixture: fixture, state: state, adapterRevision: 2)

    let refreshed = try await upgraded.refreshInstallationStates()
    let review = try XCTUnwrap(refreshed.first)
    XCTAssertEqual(review.availability, .needsReview)
    XCTAssertEqual(review.adapterRevision, 1)
    XCTAssertTrue(review.isEnabled)
    XCTAssertEqual(review.capabilities, .empty)
    XCTAssertTrue(review.lastProbeError?.contains("executable changed") == true)
    let probeCountAfterChange = await state.probeCount()
    XCTAssertEqual(probeCountAfterChange, 1)

    _ = try await upgraded.refreshInstallationStates()
    let probeCountAfterSecondRefresh = await state.probeCount()
    XCTAssertEqual(probeCountAfterSecondRefresh, 1)
    do {
      _ = try await upgraded.validateForExecution(installationID: registered.id)
      XCTFail("A changed executable must remain blocked pending review.")
    } catch let error as ServiceAgentRegistryError {
      XCTAssertEqual(error, .installationNeedsReview(registered.id))
    }
    let finalProbeCount = await state.probeCount()
    XCTAssertEqual(finalProbeCount, 1)
  }

  func testLegacyReviewReasonsRecoverWhenCurrentContentIsUnchanged() async throws {
    let fixture = try StabilityFixture()
    defer { fixture.remove() }
    let state = StabilityProbeState()
    let store = try SimpleServiceStore(path: fixture.databasePath)
    let originalRegistry = ServiceAgentRegistry(
      store: store,
      providers: [try StabilityFixtureProvider(state: state, adapterRevision: 1)]
    )
    let executableReview = try await originalRegistry.registerAndProbe(
      request(
        executable: makeExecutable(in: fixture.rootURL, named: "legacy-executable"), enabled: true)
    )
    let artifactPath = try makeConfiguration(in: fixture.rootURL, named: "legacy.yml")
    let artifactReview = try await originalRegistry.registerAndProbe(
      request(
        executable: makeExecutable(in: fixture.rootURL, named: "legacy-artifact"),
        configuration: artifactPath,
        enabled: true
      )
    )
    let adapterReview = try await originalRegistry.registerAndProbe(
      request(
        executable: makeExecutable(in: fixture.rootURL, named: "legacy-adapter"), enabled: true)
    )

    let persistedExecutable = try await store.agentInstallation(id: executableReview.id)
    let persistedArtifact = try await store.agentInstallation(id: artifactReview.id)
    let persistedAdapter = try await store.agentInstallation(id: adapterReview.id)
    try await store.updateAgentInstallation(
      try legacyReview(
        XCTUnwrap(persistedExecutable),
        reason: "The registered executable changed and requires local review.",
        adapterRevision: 2)
    )
    try await store.updateAgentInstallation(
      try legacyReview(
        XCTUnwrap(persistedArtifact),
        reason: "A registered installation artifact changed and requires local review.",
        adapterRevision: 2)
    )
    try await store.updateAgentInstallation(
      try legacyReview(
        XCTUnwrap(persistedAdapter),
        reason: "The Provider adapter changed and requires a new Probe.",
        adapterRevision: 1)
    )

    let currentRegistry = ServiceAgentRegistry(
      store: store,
      providers: [try StabilityFixtureProvider(state: state, adapterRevision: 2)]
    )
    let refreshed = try await currentRegistry.refreshInstallationStates()
    XCTAssertEqual(refreshed.count, 3)
    for record in refreshed {
      XCTAssertEqual(record.availability, .available)
      XCTAssertTrue(record.isSelectable)
      XCTAssertEqual(record.adapterRevision, 2)
      XCTAssertNil(record.lastProbeError)
    }
    let probeCount = await state.probeCount()
    XCTAssertEqual(probeCount, 6)
  }

  private func makeRegistry(
    fixture: StabilityFixture,
    state: StabilityProbeState,
    adapterRevision: Int
  ) throws -> ServiceAgentRegistry {
    ServiceAgentRegistry(
      store: try SimpleServiceStore(path: fixture.databasePath),
      providers: [try StabilityFixtureProvider(state: state, adapterRevision: adapterRevision)]
    )
  }

  private func request(
    executable: String,
    configuration: String? = nil,
    enabled: Bool
  ) throws -> ServiceAgentRegistrationRequest {
    let artifacts =
      try configuration.map {
        [try ServiceAgentInstallationArtifactRequest(role: .launchConfiguration, path: $0)]
      } ?? []
    return try ServiceAgentRegistrationRequest(
      providerID: .openCode,
      displayName: "Stability Fixture",
      executablePath: executable,
      trustProfile: .managed,
      enableOnSuccess: enabled,
      artifacts: artifacts
    )
  }

  private func makeExecutable(
    in directory: URL,
    named name: String,
    contents: String = "#!/bin/sh\nexit 0\n"
  ) throws -> String {
    let destination = directory.appendingPathComponent(name)
    let path = destination.path
    #if os(Windows)
      let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
      let source = URL(fileURLWithPath: systemRoot)
        .appendingPathComponent("System32")
        .appendingPathComponent("cmd.exe")
      try FileManager.default.copyItem(at: source, to: destination)
    #else
      try Data(contents.utf8).write(to: destination)
    #endif
    try setExecutablePermissions(at: path)
    return path
  }

  private func makeConfiguration(in directory: URL, named name: String) throws -> String {
    let path = directory.appendingPathComponent(name).path
    try Data("profile: fixture\n".utf8).write(to: URL(fileURLWithPath: path))
    #if canImport(Darwin)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o600)],
        ofItemAtPath: path
      )
    #endif
    return path
  }

  private func setExecutablePermissions(at path: String) throws {
    #if canImport(Darwin)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)],
        ofItemAtPath: path
      )
    #else
      _ = path
    #endif
  }

  private func replaceExecutableContents(at path: String, with contents: String) throws {
    #if os(Windows)
      var data = try Data(contentsOf: URL(fileURLWithPath: path))
      data.append(Data(contents.utf8))
      try data.write(to: URL(fileURLWithPath: path))
    #else
      try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
    #endif
    try setExecutablePermissions(at: path)
  }

  private func touch(_ path: String, at date: Date) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
  }

  private func legacyReview(
    _ record: ServiceAgentInstallationRecord,
    reason: String,
    adapterRevision: Int
  ) throws -> ServiceAgentInstallationRecord {
    try ServiceAgentInstallationRecord(
      id: record.id,
      providerID: record.providerID,
      displayName: record.displayName,
      executablePath: record.executablePath,
      executableIdentity: record.executableIdentity,
      version: record.version,
      protocolRevision: record.protocolRevision,
      adapterRevision: adapterRevision,
      trustProfile: record.trustProfile,
      securityProfileID: record.securityProfileID,
      isEnabled: record.isEnabled,
      availability: .needsReview,
      capabilities: .empty,
      artifacts: record.artifacts,
      lastProbeError: reason,
      lastProbedAt: record.lastProbedAt,
      createdAt: record.createdAt,
      updatedAt: record.updatedAt
    )
  }
}

private struct StabilityFixture {
  let rootURL: URL
  let databasePath: String

  init() throws {
    rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "codex-bridge-agent-stability-" + UUID().uuidString,
      isDirectory: true
    )
    databasePath = rootURL.appendingPathComponent("service.sqlite").path
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}

private enum StabilityProbeOutcome: Sendable {
  case available
  case unavailable(String)
}

private actor StabilityProbeState {
  private var outcome: StabilityProbeOutcome = .available
  private var count = 0

  func setOutcome(_ outcome: StabilityProbeOutcome) {
    self.outcome = outcome
  }

  func probeCount() -> Int {
    count
  }

  func result(for request: AgentProbeRequest) -> AgentProbeResult {
    count += 1
    guard case .available = outcome else {
      if case .unavailable(let reason) = outcome {
        return AgentProbeResult(
          installation: request.installation,
          available: false,
          capabilities: .empty,
          unavailableReason: reason
        )
      }
      fatalError("Unhandled fixture outcome")
    }
    guard
      let installation = try? AgentInstallation(
        id: request.installation.id,
        providerID: request.installation.providerID,
        executablePath: request.installation.executablePath,
        version: "1.0.0",
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
}

private struct StabilityFixtureProvider: AgentProvider, Sendable {
  let descriptor: AgentProviderDescriptor
  let state: StabilityProbeState

  init(state: StabilityProbeState, adapterRevision: Int) throws {
    descriptor = try AgentProviderDescriptor(
      providerID: .openCode,
      displayName: "Stability Fixture",
      adapterRevision: adapterRevision
    )
    self.state = state
  }

  func probe(_ request: AgentProbeRequest) async -> AgentProbeResult {
    await state.result(for: request)
  }

  func models(
    installation _: AgentInstallation,
    projectRoot _: String?,
    selectedModelID _: String?
  ) async throws -> [AgentModelDescriptor] {
    [try AgentModelDescriptor(id: "fixture-model", displayName: "Fixture Model")]
  }

  func start(
    _ request: AgentExecutionRequest,
    installation: AgentInstallation
  ) async throws -> AgentExecutionHandle {
    throw AgentRuntimeError.processUnavailable
  }
}
