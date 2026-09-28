#if os(Windows)
  import BridgeDesktopUI

  extension CodexBridgeWindowsApplication {
    static func runDesktopTunnelCommand(
      _ envelope: BridgeDesktopCommandEnvelope,
      connections: WindowsConnectionModel
    ) -> Bool {
      switch envelope.command {
      case .configureTunnel:
        guard let tunnelID = BridgeDesktopCommandValue.nonEmpty(envelope.payload.tunnelID),
          let runtimeKey = BridgeDesktopCommandValue.nonBlankText(
            envelope.payload.runtimeKey,
            maximumUTF8Bytes: 8 * 1_024
          )
        else { return true }
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
