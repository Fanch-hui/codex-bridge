#if os(Windows)
  import BridgeDesktopUI
  import XCTest
  @testable import BridgeWindowsShell

  final class WindowsDesktopTunnelStateTests: XCTestCase {
    func testLiveTunnelStatusRendersLifecycleOnBothPages() {
      let state = WindowsDesktopUIStateBuilder.build(
        workbench: makeWorkbench(),
        management: makeManagement(),
        connections: makeConnections(
          tunnel: makeTunnel(lifecycle: "ready", enabled: true, acceptsRemoteSubmissions: true)
        )
      )

      let overviewRow = state.overview?.services.first(where: { $0.id == "secure-tunnel" })
      XCTAssertEqual(overviewRow?.value, "ready")
      XCTAssertEqual(overviewRow?.symbol, "checkmark.circle.fill")
      XCTAssertEqual(overviewRow?.tone, .success)
      XCTAssertEqual(
        state.connections?.summaryRows.first(where: { $0.id == "secure-tunnel" })?.value,
        "ready"
      )
      XCTAssertEqual(state.connections?.tunnel.lifecycle, "ready")
      XCTAssertEqual(state.connections?.tunnel.tunnelID, "tunnel-9")
      XCTAssertEqual(state.connections?.tunnel.acceptsRemoteSubmissions, true)
      XCTAssertEqual(state.connections?.tunnel.canDisconnect, true)
    }

    func testTunnelLifecycleTransitionsDriveRowPresentation() {
      func row(_ tunnel: BridgeDesktopTunnelState) -> BridgeDesktopServiceRow {
        WindowsDesktopUIStateBuilder.build(
          workbench: makeWorkbench(),
          management: makeManagement(),
          connections: makeConnections(tunnel: tunnel)
        ).overview?.services.first(where: { $0.id == "secure-tunnel" })
          ?? BridgeDesktopServiceRow(id: "absent", title: "", value: "", symbol: "", tone: .error)
      }

      let connecting = row(makeTunnel(lifecycle: "connecting", enabled: true))
      XCTAssertEqual(connecting.value, "connecting")
      XCTAssertEqual(connecting.symbol, "link")
      XCTAssertEqual(connecting.tone, .running)

      let actionRequired = row(
        makeTunnel(lifecycle: "degraded", enabled: true, actionRequired: true)
      )
      XCTAssertEqual(actionRequired.value, "degraded")
      XCTAssertEqual(actionRequired.symbol, "shield.lefthalf.filled")
      XCTAssertEqual(actionRequired.tone, .warning)

      let stopped = row(makeTunnel(lifecycle: "stopped", enabled: false))
      XCTAssertEqual(stopped.value, "stopped")
      XCTAssertEqual(stopped.symbol, "circle.dashed")
      XCTAssertEqual(stopped.tone, .neutral)
    }

    func testHelperlessTunnelStatusKeepsRemoteSubmissionOff() {
      let state = WindowsDesktopUIStateBuilder.build(
        workbench: makeWorkbench(),
        management: makeManagement(),
        connections: makeConnections(
          tunnel: makeTunnel(
            lifecycle: "failed",
            enabled: false,
            configured: false,
            helperAvailable: false)
        )
      )

      XCTAssertEqual(state.connections?.tunnel.lifecycle, "failed")
      XCTAssertEqual(state.connections?.tunnel.helperAvailable, false)
      XCTAssertEqual(state.connections?.tunnel.acceptsRemoteSubmissions, false)
      XCTAssertEqual(
        state.connections?.summaryRows.first(where: { $0.id == "secure-tunnel" })?.value,
        "failed"
      )
      XCTAssertEqual(
        state.overview?.services.first(where: { $0.id == "secure-tunnel" })?.tone,
        .neutral
      )
    }

    func testTunnelWithoutServiceStatusShowsNoConfigurationYet() {
      let state = WindowsDesktopUIStateBuilder.build(
        workbench: makeWorkbench(),
        management: makeManagement(),
        connections: makeConnections(tunnel: nil)
      )

      let overviewRow = state.overview?.services.first(where: { $0.id == "secure-tunnel" })
      XCTAssertEqual(overviewRow?.value, "未配置")
      XCTAssertEqual(overviewRow?.tone, .neutral)
      XCTAssertEqual(state.connections?.tunnel.lifecycle, "stopped")
      XCTAssertEqual(state.connections?.tunnel.canConfigure, false)
      XCTAssertEqual(state.connections?.tunnel.canConnect, false)
      XCTAssertEqual(state.connections?.tunnel.canDisconnect, false)
      XCTAssertEqual(state.connections?.tunnel.canClear, false)
    }
  }
#endif
