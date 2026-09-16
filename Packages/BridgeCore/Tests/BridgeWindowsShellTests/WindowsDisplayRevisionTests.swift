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
  }
#endif
