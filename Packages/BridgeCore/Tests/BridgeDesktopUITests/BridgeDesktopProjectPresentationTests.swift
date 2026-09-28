import BridgeDesktopUI
import XCTest

final class BridgeDesktopProjectPresentationTests: XCTestCase {
  func testPermissionOptionsStayConsistentAcrossProjectEditors() {
    XCTAssertEqual(
      BridgeDesktopProjectPresentation.readPermissionOptions.map(\.id),
      ["denied", "allowed"]
    )
    XCTAssertEqual(
      BridgeDesktopProjectPresentation.guardedPermissionOptions.map(\.id),
      ["denied", "requiresLocalApproval", "allowed"]
    )
    XCTAssertEqual(
      BridgeDesktopProjectPresentation.policyOptions,
      BridgeDesktopProjectPresentation.guardedPermissionOptions
    )
  }

  func testWorkspaceCommandModesKeepStableLabelsAndUnknownValues() {
    XCTAssertEqual(
      BridgeDesktopProjectPresentation.workspaceCommandModeOptions,
      [
        BridgeDesktopChoice(id: "denied", title: "禁止直接执行"),
        BridgeDesktopChoice(id: "safe", title: "安全模式"),
        BridgeDesktopChoice(id: "full", title: "完全模式"),
      ]
    )
    XCTAssertEqual(
      BridgeDesktopProjectPresentation.workspaceCommandModeChoice("custom"),
      BridgeDesktopChoice(id: "custom", title: "custom")
    )
  }
}
