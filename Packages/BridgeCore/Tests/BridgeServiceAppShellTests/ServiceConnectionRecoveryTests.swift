import BridgeIPC
import Foundation
import XCTest

@testable import BridgeServiceAppShell

@MainActor
final class ServiceConnectionRecoveryTests: XCTestCase {
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

  func register() throws {}
  func unregister() async throws {}
  func openSystemSettings() {}
  func recoverUnavailableService() async throws -> Bool {
    recoveries += 1
    return true
  }
}
