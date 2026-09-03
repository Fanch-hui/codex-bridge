#if os(Windows)
  import BridgeDesktopUI
  import XCTest
  @testable import BridgeWindowsShell

  final class WindowsDesktopFeedbackTests: XCTestCase {
    func testStoreUsesMonotonicEventsAndExactDismissal() async {
      await MainActor.run {
        let store = WindowsDesktopFeedbackStore()
        store.postToast("已保存")
        let first = store.current
        XCTAssertEqual(first?.kind, .toast)
        XCTAssertEqual(first?.tone, .success)

        store.postAlert("保存失败")
        let second = store.current
        XCTAssertEqual(second?.kind, .alert)
        XCTAssertNotEqual(second?.id, first?.id)

        store.dismiss(id: first?.id ?? "")
        XCTAssertEqual(store.current, second)
        store.dismiss(id: second?.id ?? "")
        XCTAssertNil(store.current)
      }
    }

    func testStateBuilderCarriesCurrentFeedback() {
      let feedback = BridgeDesktopFeedback(
        id: "feedback-9",
        kind: .alert,
        tone: .error,
        title: "操作失败",
        message: "无法保存"
      )
      let state = WindowsDesktopUIStateBuilder.build(
        workbench: makeWorkbench(),
        management: makeManagement(),
        feedback: feedback
      )

      XCTAssertEqual(state.feedback, feedback)
    }

    func testTrayTooltipSummarizesLiveStatus() {
      let value = WindowsMainWindowChrome.statusTooltip(
        connectionLabel: "已连接",
        runningTasks: 2,
        pendingApprovals: 1
      )

      XCTAssertTrue(value.contains("Codex Bridge · 已连接"))
      XCTAssertTrue(value.contains("正在运行 2 个任务"))
      XCTAssertTrue(value.contains("等待处理 1 项安全审批"))
    }
  }
#endif
