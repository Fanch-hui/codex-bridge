#if os(Windows)
  import XCTest
  @testable import BridgeWindowsShell

  final class WindowsDisplayRevisionTests: XCTestCase {
    func testWorkbenchRevisionChangesOnlyWhenSnapshotChanges() {
      let box = WorkbenchDisplayBox()
      let original = box.current()
      let revision = box.revision
      for _ in 0..<100 { box.store(original) }
      XCTAssertEqual(box.revision, revision)

      var changed = original
      changed.browserEnabled.toggle()
      box.store(changed)
      XCTAssertEqual(box.revision, revision + 1)
      XCTAssertEqual(box.current(), changed)
      box.store(changed)
      XCTAssertEqual(box.revision, revision + 1)
    }

    func testAuxiliaryRevisionPreservesUnchangedSnapshots() {
      let box = AuxiliaryDisplayBox(value: ["first"])
      box.store(["first"])
      XCTAssertEqual(box.revision, 0)
      box.store(["first", "second"])
      XCTAssertEqual(box.revision, 1)
      XCTAssertEqual(box.current(), ["first", "second"])
    }

    func testUnloadedSettingsUseWorkbenchModelCatalog() {
      var workbench = makeWorkbench()
      workbench.availableModelCount = 3
      let settings = makeSettings(connectionState: .idle)
      let state = WindowsDesktopUIStateBuilder.build(
        workbench: workbench,
        management: makeManagement(),
        connections: makeConnections(tunnel: nil),
        settings: settings
      )
      XCTAssertEqual(state.connections?.codex?.modelCount, 3)
      XCTAssertEqual(state.connections?.codex?.isConnected, true)
      XCTAssertEqual(state.connections?.codex?.canRefresh, true)
    }

    func testManagementRevisionPreservesUnchangedSnapshots() {
      let value = makeManagement()
      let box = ManagementDisplayBox(value: value)
      box.store(value)
      XCTAssertEqual(box.revision, 0)
      let changed = WindowsManagementDisplay(
        connectionState: .unavailable,
        availableAgentCount: value.availableAgentCount,
        project: value.project,
        agent: value.agent
      )
      box.store(changed)
      XCTAssertEqual(box.revision, 1)
      XCTAssertEqual(box.current(), changed)
    }

    func testOverviewAgentReconnectStateChangesAndIgnoresDisabledInstallations() {
      let workbench = makeWorkbench()
      let reconnecting = makeAgentInstallationRow(
        displayName: "AGY CLI",
        enabled: true,
        availability: "needs_review"
      )
      let reconnectingState = WindowsDesktopUIStateBuilder.build(
        workbench: workbench,
        management: makeManagement(
          installationItems: [reconnecting]
        ),
        connections: makeConnections(tunnel: nil)
      )
      let reconnectingRow = reconnectingState.overview?.services.first {
        $0.id == "local-agents"
      }
      XCTAssertEqual(reconnectingRow?.value, "AGY CLI 需要重新连接")
      XCTAssertEqual(reconnectingRow?.tone, .warning)
      XCTAssertEqual(reconnectingRow?.destination, .connections)

      let disabled = makeAgentInstallationRow(
        displayName: "AGY CLI",
        enabled: false,
        availability: "unavailable"
      )
      let disabledState = WindowsDesktopUIStateBuilder.build(
        workbench: workbench,
        management: makeManagement(
          installationItems: [disabled]
        ),
        connections: makeConnections(tunnel: nil)
      )
      let disabledRow = disabledState.overview?.services.first { $0.id == "local-agents" }
      XCTAssertEqual(disabledRow?.value, "0 个可用 / 共 1 个")
      XCTAssertEqual(disabledRow?.tone, .neutral)

      let available = makeAgentInstallationRow(
        displayName: "AGY CLI",
        enabled: true,
        availability: "available"
      )
      let availableState = WindowsDesktopUIStateBuilder.build(
        workbench: workbench,
        management: makeManagement(
          availableAgentCount: 1,
          installationItems: [available]
        ),
        connections: makeConnections(tunnel: nil)
      )
      let availableRow = availableState.overview?.services.first { $0.id == "local-agents" }
      XCTAssertEqual(availableRow?.value, "1 个可用 / 共 1 个")
      XCTAssertEqual(availableRow?.tone, .success)
    }
  }
#endif
