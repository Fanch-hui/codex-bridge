import BridgeAgentCore
import BridgeDomain
import Foundation
import XCTest

@testable import BridgeServiceCore

#if canImport(Darwin)
  import Darwin
#endif

final class ServiceAgentRegistryConnectionTests: XCTestCase {
  func testConnectReusesInstallationAndPreservesAvailableRecordAfterProbeFailure() async throws {
    let fixture = try ServiceCoreFixture()
    defer { fixture.remove() }
    let executableURL = fixture.rootURL.appendingPathComponent("opencode")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
    #if canImport(Darwin)
      XCTAssertEqual(chmod(executableURL.path, 0o700), 0)
    #endif
    let state = ConnectionProbeState()
    let provider = try ConnectionFixtureProvider(state: state)
    let registry = ServiceAgentRegistry(
      store: try SimpleServiceStore(path: fixture.databasePath),
      providers: [provider],
      makeInstallationID: { AgentInstallationID(rawValue: "ainst-connect") }
    )
    let request = try ServiceAgentRegistrationRequest(
      providerID: .openCode,
      displayName: "OpenCode",
      executablePath: executableURL.path,
      trustProfile: .managed,
      securityProfileID: AgentProfileID(rawValue: "controlled-readonly")
    )

    let connected = try await registry.connect(request)
    XCTAssertTrue(connected.isSelectable)
    let installations = try await registry.installations()
    XCTAssertEqual(installations.count, 1)

    let reconnected = try await registry.connect(request)
    XCTAssertEqual(reconnected.id, connected.id)
    XCTAssertTrue(reconnected.isSelectable)
    let beforeFailure = try await registry.installation(id: connected.id)
    let reconnectedInstallations = try await registry.installations()
    XCTAssertEqual(reconnectedInstallations.count, 1)

    await state.setAvailable(false)
    do {
      _ = try await registry.connect(request)
      XCTFail("A failed reconnect must not report the previous available record.")
    } catch let error as ServiceAgentRegistryError {
      XCTAssertEqual(error, .connectionProbeFailed(connected.id))
    }

    let persisted = try await registry.installation(id: connected.id)
    XCTAssertEqual(persisted, beforeFailure)
    let probeCount = await state.probeCount()
    XCTAssertEqual(probeCount, 3)
  }
}

private actor ConnectionProbeState {
  private var available = true
  private var count = 0

  func setAvailable(_ value: Bool) {
    available = value
  }

  func probeCount() -> Int {
    count
  }

  func nextResult(for request: AgentProbeRequest) throws -> AgentProbeResult {
    count += 1
    guard available else {
      return AgentProbeResult(
        installation: request.installation,
        available: false,
        capabilities: .empty,
        unavailableReason: "The fixture Probe failed."
      )
    }
    let installation = try AgentInstallation(
      id: request.installation.id,
      providerID: request.installation.providerID,
      executablePath: request.installation.executablePath,
      version: "1.0.0",
      protocolRevision: "1"
    )
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

private struct ConnectionFixtureProvider: AgentProvider, Sendable {
  let descriptor: AgentProviderDescriptor
  let state: ConnectionProbeState

  init(state: ConnectionProbeState) throws {
    descriptor = try AgentProviderDescriptor(
      providerID: .openCode,
      displayName: "OpenCode",
      adapterRevision: 1
    )
    self.state = state
  }

  func probe(_ request: AgentProbeRequest) async -> AgentProbeResult {
    do {
      return try await state.nextResult(for: request)
    } catch {
      return AgentProbeResult(
        installation: request.installation,
        available: false,
        capabilities: .empty,
        unavailableReason: "The fixture installation is invalid."
      )
    }
  }

  func start(
    _ request: AgentExecutionRequest,
    installation: AgentInstallation
  ) async throws -> AgentExecutionHandle {
    throw AgentRuntimeError.processUnavailable
  }
}
