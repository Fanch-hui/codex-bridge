#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeMCP
  import XCTest
  @testable import BridgeWindowsShell

  final class WindowsSettingsPatchTests: XCTestCase {
    func testPatchRejectsUnsupportedExecutionEffort() {
      let current = IPCModelPreferences(
        executionModel: "model",
        executionEffort: "low",
        supervisorModel: "supervisor-model",
        supervisorEffort: "high",
        supervisorEnabled: false,
        accessMode: "request-approval",
        fastModeEnabled: false
      )
      let model = MCPModelSummary(
        modelID: "model",
        displayName: "Model",
        isDefault: false,
        reasoningEfforts: ["low"]
      )

      XCTAssertThrowsError(
        try WindowsSettingsModel.patchedPreferences(
          current: current,
          models: [model],
          patch: BridgeDesktopSettingsPatch(executionEffort: "xhigh")
        )
      ) { error in
        XCTAssertEqual(error as? WindowsSettingsPatchError, .executionEffortUnavailable)
      }
    }
  }
#endif
