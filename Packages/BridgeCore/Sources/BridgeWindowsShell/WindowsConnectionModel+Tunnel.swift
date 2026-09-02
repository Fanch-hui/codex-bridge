#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeServiceAppCore

  extension WindowsConnectionModel {
    /// `nil` until a Service status round trip has completed.
    var projectedTunnel: BridgeDesktopTunnelState? {
      guard let tunnel = serviceStatus?.tunnel else { return nil }
      let connected = connectionState == .connected
      return BridgeDesktopTunnelState(
        configured: tunnel.configured,
        enabled: tunnel.enabled,
        helperAvailable: tunnel.helperAvailable,
        tunnelID: tunnel.tunnelID,
        lifecycle: tunnel.lifecycle,
        acceptsRemoteSubmissions: tunnel.acceptsRemoteSubmissions,
        actionRequired: tunnel.actionRequired,
        canConfigure: connected && tunnel.helperAvailable,
        canConnect: connected && tunnel.configured && tunnel.helperAvailable && !tunnel.enabled,
        canDisconnect: connected && tunnel.enabled,
        canClear: connected && tunnel.configured
      )
    }

    func configureTunnel(tunnelID: String, runtimeKey: String) async {
      await mutate("正在配置 Secure Tunnel…") {
        _ = try await self.client.configureTunnel(
          IPCTunnelConfigurationRequest(tunnelID: tunnelID, runtimeKey: runtimeKey)
        )
      }
    }

    func connectTunnel() async {
      await mutate("正在连接 Secure Tunnel…") {
        _ = try await self.client.connectTunnel()
      }
    }

    func disconnectTunnel() async {
      await mutate("正在断开 Secure Tunnel…") {
        try await self.client.disconnectTunnel()
      }
    }

    func clearTunnel() async {
      await mutate("正在清除 Secure Tunnel 配置…") {
        try await self.client.clearTunnel()
      }
    }
  }
#endif
