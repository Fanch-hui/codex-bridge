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
    model.scheduleAgentDiscoveryUpgradeIfNeeded()
    XCTAssertFalse(model.didAttemptAgentDiscoveryUpgrade)
    setExecution("idle")
    model.scheduleAgentDiscoveryUpgradeIfNeeded()
    model.scheduleAgentDiscoveryUpgradeIfNeeded()
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
