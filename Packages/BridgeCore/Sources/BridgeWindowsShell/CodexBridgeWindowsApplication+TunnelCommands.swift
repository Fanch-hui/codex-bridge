#if os(Windows)
  extension CodexBridgeWindowsApplication {
    static func runTunnelCommand(
      _ command: MainWindowCommand,
      connections: WindowsConnectionModel
    ) -> Bool {
      switch command {
      case .configureTunnel(let tunnelID, let runtimeKey):
        Task { @MainActor in
          await connections.configureTunnel(tunnelID: tunnelID, runtimeKey: runtimeKey)
        }
      case .connectTunnel:
        Task { @MainActor in await connections.connectTunnel() }
      case .disconnectTunnel:
        Task { @MainActor in await connections.disconnectTunnel() }
      case .clearTunnel:
        Task { @MainActor in await connections.clearTunnel() }
      default:
        return false
      }
      return true
    }
  }
#endif
