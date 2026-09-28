#if os(Windows)
  import BridgeDesktopUI
  @testable import BridgeWindowsShell
  import XCTest

  final class WindowsNativePermissionDesktopTests: XCTestCase {
    func testWindowsStateProjectsNativePolicyAndRemediationIntoSharedUI() {
      let policy = BridgeDesktopNativePermissionState(
        providerID: "antigravity",
        providerName: "Antigravity",
        installationID: "ainst-agy",
        installationName: "AGY CLI",
        installations: [BridgeDesktopChoice(id: "ainst-agy", title: "AGY CLI")],
        toolPermission: "request-review",
        availableModes: [
          BridgeDesktopNativePermissionMode(
            modeID: "request-review",
            displayName: "Request Review"
          )
        ],
        availableActions: ["command"],
        canEdit: true
      )
      let remediation = BridgeDesktopPermissionRemediationState(
        messageKey: "tool:command-1",
        installationID: "ainst-agy",
        candidateID: "candidate-1",
        action: "command",
        target: "swift test",
        displayRule: "command(swift test)",
        requiresConfirmation: true
      )
      var workbench = makeWorkbench()
      workbench.selectedTaskDetail = BridgeDesktopTaskDetail(
        taskID: "task-1",
        title: "Run tests",
        projectName: "Bridge",
        status: "失败",
        provider: "Antigravity",
        failureCode: "antigravity_permission_denied",
        permissionRemediation: remediation,
        updatedAt: "2026-09-03T00:00:00Z"
      )
      workbench.approvalItems = [
        BridgeDesktopApprovalRow(
          approvalID: "approval-1",
          taskID: "task-1",
          kind: "task_start",
          title: "启动任务",
          summary: "等待本机批准",
          oneTimeToolAutoApprovalAvailable: true
        )
      ]
      let state = WindowsDesktopUIStateBuilder.build(
        workbench: workbench,
        management: makeManagement(),
        settings: makeSettings(),
        agentDefaults: agentDefaultsDisplay(nativePermissionPolicy: policy),
        selectedNavigation: .settings
      )

      XCTAssertEqual(state.settings?.nativePermissionPolicy, policy)
      XCTAssertEqual(state.workbench?.selectedTask?.permissionRemediation, remediation)
      XCTAssertTrue(
        state.workbench?.approvals.first?.oneTimeToolAutoApprovalAvailable == true
      )
    }

    private func agentDefaultsDisplay(
      nativePermissionPolicy: BridgeDesktopNativePermissionState
    ) -> WindowsAgentDefaultsDisplay {
      WindowsAgentDefaultsDisplay(
        connectionState: .connected,
        providerRows: [],
        selectedProviderIndex: nil,
        installationRows: [],
        selectedInstallationIndex: nil,
        installationDetailText: "",
        modelRows: [],
        modelIDs: [],
        selectedModelIndex: nil,
        effortValues: [""],
        selectedEffortIndex: 0,
        permissionValues: ["read-only"],
        selectedPermissionIndex: 0,
        refreshModelsEnabled: false,
        saveEnabled: false,
        statusText: "就绪",
        nativePermissionPolicy: nativePermissionPolicy
      )
    }
  }
#endif
