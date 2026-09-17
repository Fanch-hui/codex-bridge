#if os(Windows)
  import BridgeDesktopUI

  /// Tunnel projection shared by the overview and connections pages so both
  /// render the same Service-reported lifecycle.
  extension WindowsDesktopUIStateBuilder {
    static let tunnelRowID = "secure-tunnel"
    static let tunnelTitle = "远程 Secure Tunnel"

    static let tunnelWithoutServiceStatus = BridgeDesktopTunnelState(
      configured: false,
      enabled: false,
      helperAvailable: false,
      lifecycle: "stopped",
      acceptsRemoteSubmissions: false,
      actionRequired: false,
      canConfigure: false
    )

    static func overviewTunnelRow(
      _ tunnel: BridgeDesktopTunnelState?
    ) -> BridgeDesktopServiceRow {
      guard let tunnel else {
        return BridgeDesktopServiceRow(
          id: tunnelRowID,
          title: tunnelTitle,
          value: "未配置",
          symbol: "link",
          tone: .neutral,
          destination: .connections
        )
      }
      let lifecycle = tunnel.lifecycle.isEmpty ? "未知" : tunnel.lifecycle
      return BridgeDesktopServiceRow(
        id: tunnelRowID,
        title: tunnelTitle,
        value: lifecycle,
        symbol: overviewTunnelSymbol(tunnel),
        tone: overviewTunnelTone(tunnel),
        destination: .connections
      )
    }

    static func connectionsTunnelRow(
      _ tunnel: BridgeDesktopTunnelState
    ) -> BridgeDesktopServiceRow {
      BridgeDesktopServiceRow(
        id: tunnelRowID,
        title: tunnelTitle,
        value: tunnel.lifecycle.isEmpty ? "unknown" : tunnel.lifecycle,
        symbol: tunnel.enabled ? "link" : "circle.dashed",
        tone: tunnel.lifecycle == "ready" ? .success : tunnel.enabled ? .running : .neutral
      )
    }

    private static func overviewTunnelSymbol(
      _ tunnel: BridgeDesktopTunnelState
    ) -> String {
      if tunnel.lifecycle == "ready" { return "checkmark.circle.fill" }
      if tunnel.actionRequired { return "shield.lefthalf.filled" }
      return tunnel.enabled ? "link" : "circle.dashed"
    }

    private static func overviewTunnelTone(
      _ tunnel: BridgeDesktopTunnelState
    ) -> BridgeDesktopStatusTone {
      if tunnel.lifecycle == "ready" { return .success }
      if tunnel.actionRequired { return .warning }
      return tunnel.enabled ? .running : .neutral
    }
  }
#endif
