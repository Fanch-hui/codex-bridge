#if os(Windows)
  import BridgeDesktopUI
  import Foundation
  @testable import BridgeWindowsShell
  import XCTest

  final class WindowsNativePermissionDesktopTests: XCTestCase {
    func testOneTimeApprovalRequiresConfirmationAndPreservesIntent() {
      let unconfirmed = envelope(
        .resolveApproval,
        payload: BridgeDesktopCommandPayload(
          taskID: "task-1",
          approvalID: "approval-1",
          decision: "allow",
          oneTimeToolAutoApproval: true
        )
      )
      XCTAssertNil(WindowsDesktopUICommandRouter.command(for: unconfirmed))

      let confirmed = envelope(
        .resolveApproval,
        payload: BridgeDesktopCommandPayload(
          taskID: "task-1",
          approvalID: "approval-1",
          decision: "allow",
          oneTimeToolAutoApproval: true,
          confirmed: true
        )
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(for: confirmed),
        .resolveTaskApproval(
          approvalID: "approval-1",
          taskID: "task-1",
          decision: "allow",
          oneTimeToolAutoApproval: true
        )
      )
    }

    func testNativePermissionCommandsMapToTypedWindowCommands() {
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(
          for: envelope(
            .refreshAgentNativePermission,
            payload: BridgeDesktopCommandPayload(installationID: "ainst-agy")
          )
        ),
        .refreshAgentNativePermission(installationID: "ainst-agy")
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(
          for: envelope(
            .setAgentNativePermissionMode,
            payload: BridgeDesktopCommandPayload(
              installationID: "ainst-agy",
              toolPermission: "always-proceed",
              confirmed: true
            )
          )
        ),
        .setAgentNativePermissionMode(
          installationID: "ainst-agy",
          mode: "always-proceed",
          confirmed: true
        )
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(
          for: envelope(
            .replaceAgentNativePermissionRule,
            payload: BridgeDesktopCommandPayload(
              installationID: "ainst-agy",
              ruleID: "rule-1",
              effect: "allow",
              action: "command",
              target: "swift test",
              confirmed: false
            )
          )
        ),
        .replaceAgentNativePermissionRule(
          installationID: "ainst-agy",
          ruleID: "rule-1",
          effect: "allow",
          action: "command",
          target: "swift test",
          confirmed: false
        )
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(
          for: envelope(
            .addAgentNativePermissionRule,
            payload: BridgeDesktopCommandPayload(
              installationID: "ainst-agy",
              effect: "allow",
              action: "command",
              target: "swift test",
              confirmed: true
            )
          )
        ),
        .addAgentNativePermissionRule(
          installationID: "ainst-agy",
          effect: "allow",
          action: "command",
          target: "swift test",
          confirmed: true
        )
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(
          for: envelope(
            .removeAgentNativePermissionRule,
            payload: BridgeDesktopCommandPayload(
              installationID: "ainst-agy",
              ruleID: "rule-1"
            )
          )
        ),
        .removeAgentNativePermissionRule(
          installationID: "ainst-agy",
          ruleID: "rule-1"
        )
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(
          for: envelope(
            .prepareAgentPermissionRemediation,
            payload: BridgeDesktopCommandPayload(
              taskID: "task-1",
              messageKey: "tool:command-1"
            )
          )
        ),
        .prepareAgentPermissionRemediation(
          taskID: "task-1",
          messageKey: "tool:command-1"
        )
      )
    }

    func testApplyingPermissionRemediationRequiresConfirmation() {
      let unconfirmed = envelope(
        .applyAgentPermissionRemediation,
        payload: BridgeDesktopCommandPayload(
          taskID: "task-1",
          messageKey: "tool:command-1"
        )
      )
      XCTAssertNil(WindowsDesktopUICommandRouter.command(for: unconfirmed))

      let confirmed = envelope(
        .applyAgentPermissionRemediation,
        payload: BridgeDesktopCommandPayload(
          taskID: "task-1",
          messageKey: "tool:command-1",
          confirmed: true
        )
      )
      XCTAssertEqual(
        WindowsDesktopUICommandRouter.command(for: confirmed),
        .applyAgentPermissionRemediation(
          taskID: "task-1",
          messageKey: "tool:command-1",
          confirmed: true
        )
      )
    }

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

    private func envelope(
      _ command: BridgeDesktopCommand,
      payload: BridgeDesktopCommandPayload
    ) -> BridgeDesktopCommandEnvelope {
      BridgeDesktopCommandEnvelope(
        requestID: UUID().uuidString,
        command: command,
        payload: payload
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
