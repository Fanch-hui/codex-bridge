#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeMCP
  import XCTest
  @testable import BridgeWindowsShell

  final class WindowsSettingsPatchTests: XCTestCase {
    func testPatchPreservesSupervisorValuesButAlwaysDisablesSupervisor() throws {
      let current = IPCModelPreferences(
        executionModel: "old-model",
        executionEffort: "medium",
        supervisorModel: "supervisor-model",
        supervisorEffort: "high",
        supervisorEnabled: true,
        accessMode: "request-approval",
        fastModeEnabled: false
      )
      let model = MCPModelSummary(
        modelID: "new-model",
        displayName: "New Model",
        isDefault: false,
        reasoningEfforts: ["low", "high"],
        defaultReasoningEffort: "high",
        serviceTiers: ["fast"]
      )

      let result = try WindowsSettingsModel.patchedPreferences(
        current: current,
        models: [model],
        patch: BridgeDesktopSettingsPatch(
          executionModel: "new-model",
          fastModeEnabled: true
        )
      )

      XCTAssertEqual(result.executionModel, "new-model")
      XCTAssertEqual(result.executionEffort, "high")
      XCTAssertEqual(result.supervisorModel, "supervisor-model")
      XCTAssertEqual(result.supervisorEffort, "high")
      XCTAssertFalse(result.supervisorEnabled)
      XCTAssertTrue(result.fastModeEnabled)
    }

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
