import BridgeAgentCore
import Foundation
import XCTest

@testable import BridgeServiceCore

final class ServiceAgentRegistryRecoveryTests: XCTestCase {
  func testEnabledUnavailableInstallationRecoversAfterCooldown() async throws {
    let scenario = try await makeScenario(name: "recoverable-agent", id: "ainst-recoverable")
    defer { scenario.fixture.remove() }

    await scenario.state.setAvailable(false)
    let unavailable = try await scenario.registry.reprobe(
      installationID: scenario.registered.id
    )
    XCTAssertEqual(unavailable.availability, .unavailable)
    XCTAssertTrue(unavailable.isEnabled)
    var probeCount = await scenario.state.probeCount()
    XCTAssertEqual(probeCount, 2)

    await scenario.state.setAvailable(true)
    let duringCooldown = try await scenario.registry.refreshInstallationStates()
    XCTAssertEqual(duringCooldown.first?.availability, .unavailable)
    XCTAssertTrue(duringCooldown.first?.isEnabled == true)
    probeCount = await scenario.state.probeCount()
    XCTAssertEqual(probeCount, 2)

    scenario.clock.advance(by: 31)
    let recovered = try await scenario.registry.refreshInstallationStates()
    let record = try XCTUnwrap(recovered.first)
    XCTAssertEqual(record.availability, .available)
    XCTAssertTrue(record.isEnabled)
    XCTAssertTrue(record.isSelectable)
    XCTAssertNil(record.lastProbeError)
    probeCount = await scenario.state.probeCount()
    XCTAssertEqual(probeCount, 3)
  }

  func testDisabledUnavailableInstallationDoesNotAutoRecover() async throws {
    let scenario = try await makeScenario(name: "disabled-agent", id: "ainst-disabled")
    defer { scenario.fixture.remove() }

    await scenario.state.setAvailable(false)
    let unavailable = try await scenario.registry.reprobe(
      installationID: scenario.registered.id
    )
    let disabled = try await scenario.registry.setEnabled(false, installationID: unavailable.id)
    XCTAssertEqual(disabled.availability, .unavailable)
    XCTAssertFalse(disabled.isEnabled)

    await scenario.state.setAvailable(true)
    scenario.clock.advance(by: 31)
    let refreshed = try await scenario.registry.refreshInstallationStates()
    let record = try XCTUnwrap(refreshed.first)
    XCTAssertEqual(record.availability, .unavailable)
    XCTAssertFalse(record.isEnabled)
    let probeCount = await scenario.state.probeCount()
    XCTAssertEqual(probeCount, 2)
  }

  func testStaleUnavailableRefreshCannotOverwriteNewConnection() async throws {
    let scenario = try await makeScenario(
      name: "connected-agent",
      id: "ainst-connection-race"
    )
    defer { scenario.fixture.remove() }
    let gate = RegistryNowGate(date: scenario.clock.now())
    let staleRegistry = ServiceAgentRegistry(
      store: scenario.store,
      providers: [],
      now: { gate.now() }
    )
    let staleRefresh = Task {
      try await staleRegistry.refreshInstallationStates()
    }
    XCTAssertTrue(gate.waitUntilEntered())

    let connected = try await scenario.registry.connect(
      request(
        executable: scenario.executable,
        enabled: false,
        displayName: "Reconnected Fixture"
      )
    )
    XCTAssertEqual(connected.id, scenario.registered.id)
    XCTAssertEqual(connected.availability, .available)
    XCTAssertTrue(connected.isEnabled)

    gate.release()
    let staleResult = try await staleRefresh.value
    let current = try XCTUnwrap(staleResult.first)
    XCTAssertEqual(current, connected)
    let persisted = try await scenario.store.agentInstallation(id: scenario.registered.id)
    XCTAssertEqual(persisted, connected)
  }

  func testStaleUnavailableRefreshCannotOverwriteNewDisable() async throws {
    let scenario = try await makeScenario(name: "disabled-race-agent", id: "ainst-disable-race")
    defer { scenario.fixture.remove() }
    let gate = RegistryNowGate(date: scenario.clock.now())
    let staleRegistry = ServiceAgentRegistry(
      store: scenario.store,
      providers: [],
      now: { gate.now() }
    )
    let staleRefresh = Task {
      try await staleRegistry.refreshInstallationStates()
    }
    XCTAssertTrue(gate.waitUntilEntered())

    let disabled = try await scenario.registry.setEnabled(
      false,
      installationID: scenario.registered.id
    )
    XCTAssertFalse(disabled.isEnabled)
    XCTAssertEqual(disabled.availability, .available)

    gate.release()
    let staleResult = try await staleRefresh.value
    let current = try XCTUnwrap(staleResult.first)
    XCTAssertEqual(current, disabled)
    let persisted = try await scenario.store.agentInstallation(id: scenario.registered.id)
    XCTAssertEqual(persisted, disabled)
  }

  private func makeScenario(name: String, id: String) async throws -> RecoveryScenario {
    let fixture = try RecoveryFixture()
    let executable = try makeExecutable(in: fixture.rootURL, named: name)
    let state = RecoveryProbeState()
    let clock = RecoveryTestClock()
    let provider = try RecoveryFixtureProvider(state: state)
    let store = try SimpleServiceStore(path: fixture.databasePath)
    let registry = makeRegistry(
      store: store,
      provider: provider,
      clock: clock,
      id: id
    )
    let registered = try await registry.registerAndProbe(
      request(executable: executable, enabled: true)
    )
    return RecoveryScenario(
      fixture: fixture,
      executable: executable,
      state: state,
      clock: clock,
      store: store,
      registry: registry,
      registered: registered
    )
  }

  private func makeRegistry(
    store: SimpleServiceStore,
    provider: RecoveryFixtureProvider,
    clock: RecoveryTestClock,
    id: String
  ) -> ServiceAgentRegistry {
    ServiceAgentRegistry(
      store: store,
      providers: [provider],
      makeInstallationID: { AgentInstallationID(rawValue: id) },
      now: { clock.now() }
    )
  }

  private func request(
    executable: String,
    enabled: Bool,
    displayName: String = "Recovery Fixture"
  ) throws
    -> ServiceAgentRegistrationRequest
  {
    try ServiceAgentRegistrationRequest(
      providerID: .openCode,
      displayName: displayName,
      executablePath: executable,
      trustProfile: .managed,
      enableOnSuccess: enabled
    )
  }

  private func makeExecutable(in directory: URL, named name: String) throws -> String {
    let destination = directory.appendingPathComponent(name)
    #if os(Windows)
      let systemRoot = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
      let source = URL(fileURLWithPath: systemRoot)
        .appendingPathComponent("System32")
        .appendingPathComponent("cmd.exe")
      try FileManager.default.copyItem(at: source, to: destination)
    #else
      try Data("#!/bin/sh\nexit 0\n".utf8).write(to: destination)
      try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: 0o700)],
        ofItemAtPath: destination.path
      )
    #endif
    return destination.path
  }
}

private struct RecoveryFixture {
  let rootURL: URL
  let databasePath: String

  init() throws {
    rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "codex-bridge-agent-recovery-" + UUID().uuidString,
      isDirectory: true
    )
    databasePath = rootURL.appendingPathComponent("service.sqlite").path
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}

private final class RecoveryTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(start: Date = Date(timeIntervalSince1970: 1_900_000_000)) {
    value = start
  }

  func now() -> Date {
    lock.withLock { value }
  }

  func advance(by interval: TimeInterval) {
    lock.withLock { value = value.addingTimeInterval(interval) }
  }
}

private final class RegistryNowGate: @unchecked Sendable {
  private let entered = DispatchSemaphore(value: 0)
  private let releaseSignal = DispatchSemaphore(value: 0)
  private let value: Date

  init(date: Date) {
    value = date
  }

  func now() -> Date {
    entered.signal()
    releaseSignal.wait()
    return value
  }

  func waitUntilEntered() -> Bool {
    entered.wait(timeout: .now() + 2) == .success
  }

  func release() {
    releaseSignal.signal()
  }
}

private actor RecoveryProbeState {
  private var available = true
  private var count = 0

  func setAvailable(_ value: Bool) {
    available = value
  }

  func probeCount() -> Int {
    count
  }

  func result(for request: AgentProbeRequest) -> AgentProbeResult {
    count += 1
    guard available else {
      return AgentProbeResult(
        installation: request.installation,
        available: false,
        capabilities: .empty,
        unavailableReason: "The fixture Probe is temporarily unavailable."
      )
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

private struct RecoveryFixtureProvider: AgentProvider, Sendable {
  let descriptor: AgentProviderDescriptor
  let state: RecoveryProbeState

  init(state: RecoveryProbeState) throws {
    descriptor = try AgentProviderDescriptor(
      providerID: .openCode,
      displayName: "Recovery Fixture",
      adapterRevision: 1
    )
    self.state = state
  }

  func probe(_ request: AgentProbeRequest) async -> AgentProbeResult {
    await state.result(for: request)
  }

  func start(
    _ request: AgentExecutionRequest,
    installation: AgentInstallation
  ) async throws -> AgentExecutionHandle {
    throw AgentRuntimeError.processUnavailable
  }
}

private struct RecoveryScenario {
  let fixture: RecoveryFixture
  let executable: String
  let state: RecoveryProbeState
  let clock: RecoveryTestClock
  let store: SimpleServiceStore
  let registry: ServiceAgentRegistry
  let registered: ServiceAgentInstallationRecord
}
