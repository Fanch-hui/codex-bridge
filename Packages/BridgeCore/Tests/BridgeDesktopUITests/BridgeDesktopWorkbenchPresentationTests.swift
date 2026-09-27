import BridgeDesktopUI
import XCTest

final class BridgeDesktopWorkbenchPresentationTests: XCTestCase {
  func testPermissionChoicesUseStablePermissionValues() {
    let modes = BridgeDesktopWorkbenchPermissionMode.allCases

    XCTAssertEqual(
      BridgeDesktopWorkbenchPermissionMode.choices.map(\.id),
      modes.map(\.rawValue)
    )
    for mode in modes {
      XCTAssertEqual(BridgeDesktopWorkbenchPermissionMode(rawValue: mode.rawValue), mode)
    }
    XCTAssertNil(BridgeDesktopWorkbenchPermissionMode(rawValue: "workspace write"))
  }

  func testSteerModeCopyIsSharedAcrossHosts() {
    XCTAssertEqual(
      BridgeDesktopWorkbenchPresentation.steerModes(supportsImmediateSteer: false),
      [BridgeDesktopChoice(id: "queued", title: "当前轮结束后继续")]
    )
    let immediateMode = BridgeDesktopWorkbenchPresentation.steerModes(
      supportsImmediateSteer: true
    ).last
    XCTAssertEqual(immediateMode?.id, "interrupt-current-then-continue")
    XCTAssertEqual(immediateMode?.title, "中断当前轮并继续")
  }

  func testWorkbenchStatusToneMatchesRawAndDisplayedStatuses() {
    let equivalentStatuses = [
      ("running", "运行中", "running"),
      ("starting", "正在启动", "running"),
      ("completed", "已完成", "success"),
      ("failed", "失败", "error"),
      ("awaiting_local_approval", "等待本机批准", "warning"),
      ("waiting_for_codex_approval", "等待 Codex 审批", "warning"),
    ]

    for (rawStatus, displayedStatus, tone) in equivalentStatuses {
      XCTAssertEqual(BridgeDesktopWorkbenchPresentation.statusTone(for: rawStatus), tone)
      XCTAssertEqual(BridgeDesktopWorkbenchPresentation.statusTone(for: displayedStatus), tone)
    }
    XCTAssertEqual(BridgeDesktopWorkbenchPresentation.statusTone(for: "等待回答"), "warning")
  }
}
