import BridgeDesktopUI
import XCTest

@testable import BridgeServiceAppShell

final class DesktopServicePresentationTests: XCTestCase {
  func testSystemApprovalOffersSettingsInsteadOfRegistration() async {
    await MainActor.run {
      let state = BridgeDesktopUIStateBuilder.servicePresentation(
        status: .requiresApproval, keepServiceRunningAfterExit: true)
      XCTAssertEqual(state.title, "等待批准")
      XCTAssertEqual(state.actions.map(\.command), [.openSystemSettings])
      let missing = BridgeDesktopUIStateBuilder.servicePresentation(
        status: .notFound, keepServiceRunningAfterExit: true)
      XCTAssertEqual(missing.tone, .error)
      XCTAssertFalse(missing.actions.contains { $0.command == .registerService })
    }
  }
}
