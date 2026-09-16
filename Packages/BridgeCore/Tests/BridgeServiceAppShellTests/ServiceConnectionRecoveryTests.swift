import BridgeIPC
import BridgeMCP
import Foundation
import XCTest

@testable import BridgeServiceAppShell

@MainActor
final class ServiceConnectionRecoveryTests: XCTestCase {
  func testDiscoveryUpgradeWaitsForIdleAndRunsOnce() async throws {
    let registration = RecoveringServiceRegistration()
    let model = BridgeServiceAppModel(
      registration: registration, clientFactory: { TestBridgeServiceClient() },
      pollInterval: nil, maximumConnectionAttempts: 1
    )
    model.connectionState = .connected
    model.agentProviders = [
      IPCAgentProviderSummary(providerID: "opencode", displayName: "OpenCode", adapterRevision: 1)
    ]
    func setExecution(_ state: String) {
      model.serviceStatus = IPCServiceStatusResponse(
        status: BridgeStatusSnapshot(
          appVersion: "old", mcpState: "ready", tunnelState: "stopped",
          executionState: state, supervisorState: "ready", pendingApprovalCount: 0
        ), localMCPURL: nil, exposureMode: .readOnly
      )
    }
    setExecution("active")
    model.scheduleServiceUpgradeIfNeeded()
    XCTAssertFalse(model.didAttemptServiceUpgrade)
    setExecution("idle")
    model.scheduleServiceUpgradeIfNeeded()
    model.scheduleServiceUpgradeIfNeeded()
    for _ in 0..<100 where registration.recoveries == 0 {
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertEqual(registration.recoveries, 1)
    await model.shutdownUI()
  }

  func testUnavailableServiceRegistrationRecoversAndReconnects() async {
    let registration = RecoveringServiceRegistration()
    let client = TestBridgeServiceClient()
    let missingService = "org.codexbridge.tests.\(UUID().uuidString)"
    let model = BridgeServiceAppModel(
      registration: registration,
      clientFactory: {
        if registration.recoveries == 0 {
          return BridgeServiceClient(machServiceName: missingService)
        }
        return client
      },
      pollInterval: nil,
      maximumConnectionAttempts: 1
    )
    await model.startAsync()
    XCTAssertEqual(registration.recoveries, 1)
    XCTAssertEqual(model.connectionState, .connected)
    XCTAssertEqual(model.serviceStatus?.status.mcpState, "ready")
    await model.shutdownUI()
  }

  func testUnavailableStartupKeepsRetryingUntilServiceAppears() async throws {
    let missingService = "org.codexbridge.tests.\(UUID().uuidString)"
    let factory = StartupClientFactory(
      unavailable: BridgeServiceClient(machServiceName: missingService),
      available: TestBridgeServiceClient()
    )
    let model = BridgeServiceAppModel(
      registration: NonRecoveringServiceRegistration(),
      clientFactory: { factory.makeClient() },
      pollInterval: .milliseconds(1),
      connectionRetryDelay: .milliseconds(1),
      maximumConnectionAttempts: 1
    )

    await model.startAsync()

    for _ in 0..<100 where model.connectionState != .connected {
      try await Task.sleep(for: .milliseconds(1))
    }
    XCTAssertEqual(model.connectionState, .connected)
    XCTAssertGreaterThanOrEqual(factory.makeCount, 2)
    await model.shutdownUI()
  }

  func testActiveTunnelKeepsPollingAtLiveIntervalUntilReady() {
    let model = BridgeServiceAppModel(
      registration: NonRecoveringServiceRegistration(),
      clientFactory: { TestBridgeServiceClient() },
      pollInterval: .seconds(2)
    )
    model.connectionState = .connected
    model.serviceStatus = IPCServiceStatusResponse(
      status: BridgeStatusSnapshot(
        appVersion: "test", mcpState: "ready", tunnelState: "starting",
        executionState: "ready", supervisorState: "ready", pendingApprovalCount: 0
      ),
      localMCPURL: nil,
      exposureMode: .readOnly,
      tunnel: IPCTunnelStatus(
        configured: true,
        enabled: true,
        helperAvailable: true,
        tunnelID: "tunnel-1",
        lifecycle: "starting",
        acceptsRemoteSubmissions: false,
        actionRequired: false
      )
    )

    XCTAssertEqual(model.nextPollingDelay(base: .seconds(2)), .seconds(2))

    model.serviceStatus = IPCServiceStatusResponse(
      status: model.serviceStatus!.status,
      localMCPURL: nil,
      exposureMode: .readOnly,
      tunnel: IPCTunnelStatus(
        configured: true,
        enabled: true,
        helperAvailable: true,
        tunnelID: "tunnel-1",
        lifecycle: "ready",
        acceptsRemoteSubmissions: true,
        actionRequired: false
      )
    )
    XCTAssertEqual(model.nextPollingDelay(base: .seconds(2)), .seconds(10))
  }
}

@MainActor
private final class RecoveringServiceRegistration: BridgeServiceRegistrationManaging {
  var status: BridgeServiceRegistrationStatus = .enabled
  var recoveries = 0
  var supportsAutomaticRecovery: Bool { true }

  func register() throws {}
  func unregister() async throws {}
  func openSystemSettings() {}
  func recoverUnavailableService() async throws -> Bool {
    recoveries += 1
    return true
  }
}

@MainActor
private final class NonRecoveringServiceRegistration: BridgeServiceRegistrationManaging {
  var status: BridgeServiceRegistrationStatus = .enabled

  func register() throws {}
  func unregister() async throws {}
  func openSystemSettings() {}
}

@MainActor
private final class StartupClientFactory {
  private let unavailable: any BridgeServiceClientProtocol
  private let available: any BridgeServiceClientProtocol
  private(set) var makeCount = 0

  init(
    unavailable: any BridgeServiceClientProtocol,
    available: any BridgeServiceClientProtocol
  ) {
    self.unavailable = unavailable
    self.available = available
  }

  func makeClient() -> any BridgeServiceClientProtocol {
    makeCount += 1
    return makeCount == 1 ? unavailable : available
  }
}
