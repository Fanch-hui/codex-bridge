#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import Foundation

  extension CodexBridgeWindowsApplication {
    static func runDesktopConnectionCommand(
      _ envelope: BridgeDesktopCommandEnvelope,
      management: WindowsManagementModel,
      auxiliary: WindowsAuxiliaryRuntime
    ) -> Bool {
      if runDesktopAgentCommand(envelope, management: management, auxiliary: auxiliary) {
        return true
      }
      if runDesktopTunnelCommand(envelope, connections: auxiliary.connections) {
        return true
      }
      return runDesktopMCPCommand(envelope, auxiliary: auxiliary)
    }

    private static func runDesktopMCPCommand(
      _ envelope: BridgeDesktopCommandEnvelope,
      auxiliary: WindowsAuxiliaryRuntime
    ) -> Bool {
      let payload = envelope.payload
      switch envelope.command {
      case .setMCPClientEnabled:
        guard let clientID = BridgeDesktopCommandValue.nonEmpty(payload.clientID),
          let enabled = payload.enabled,
          let index = auxiliary.connections.clients.firstIndex(where: { $0.clientID == clientID })
        else { return true }
        auxiliary.connections.selectClient(at: index)
        guard auxiliary.connections.clients[index].enabled != enabled else { return true }
        Task { @MainActor in await auxiliary.connections.toggleSelectedClient(clientID: clientID) }
      case .setMCPClientExposure:
        guard let clientID = BridgeDesktopCommandValue.nonEmpty(payload.clientID),
          let mode = BridgeDesktopCommandValue.nonEmpty(payload.exposureMode),
          let modeIndex = ["read-only", "full"].firstIndex(of: mode),
          let clientIndex = auxiliary.connections.clients.firstIndex(where: {
            $0.clientID == clientID
          })
        else { return true }
        auxiliary.connections.selectClient(at: clientIndex)
        Task { @MainActor in
          await auxiliary.connections.setSelectedExposure(at: modeIndex, clientID: clientID)
        }
      case .copyMCPClientConfiguration:
        guard let clientID = BridgeDesktopCommandValue.nonEmpty(payload.clientID),
          let index = auxiliary.connections.clients.firstIndex(where: { $0.clientID == clientID })
        else { return true }
        auxiliary.connections.selectClient(at: index)
        Task { @MainActor in
          guard
            let configuration = await auxiliary.connections.exportSelectedConfiguration(
              clientID: clientID
            )
          else { return }
          auxiliary.connections.didCopyConfiguration(
            WindowsClipboard.write(configuration, owner: WindowsMainWindow.currentWindow()))
        }
      case .copyLocalMCPEndpoint:
        guard let endpoint = auxiliary.connections.localMCPEndpoint else { return true }
        auxiliary.connections.didCopyEndpoint(
          WindowsClipboard.write(endpoint, owner: WindowsMainWindow.currentWindow()))
      case .rotateMCPClientCredential:
        guard let clientID = BridgeDesktopCommandValue.nonEmpty(payload.clientID),
          let index = auxiliary.connections.clients.firstIndex(where: { $0.clientID == clientID })
        else { return true }
        auxiliary.connections.selectClient(at: index)
        Task { @MainActor in
          await auxiliary.connections.rotateSelectedCredential(clientID: clientID)
        }
      case .rotateLocalMCPEndpoint:
        Task { @MainActor in await auxiliary.connections.rotateEndpoint() }
      case .saveDeepSeekHarnessMCPServer:
        return saveMCPServer(payload, auxiliary: auxiliary)
      case .deleteDeepSeekHarnessMCPServer:
        guard let id = BridgeDesktopCommandValue.nonEmpty(payload.mcpServerID),
          let scope = mcpScope(payload)
        else { return true }
        Task { @MainActor in
          await auxiliary.connections.deleteDeepSeekHarnessMCPServer(id: id, scope: scope)
        }
      case .setDeepSeekHarnessMCPServerEnabled:
        guard let id = BridgeDesktopCommandValue.nonEmpty(payload.mcpServerID),
          let enabled = payload.enabled,
          let scope = mcpScope(payload)
        else { return true }
        Task { @MainActor in
          await auxiliary.connections.setDeepSeekHarnessMCPServerEnabled(
            id: id,
            enabled: enabled,
            scope: scope
          )
        }
      case .setAgentMCPScope:
        guard let scope = mcpScope(payload) else { return true }
        auxiliary.connections.selectAgentMCPScope(scope)
      default:
        return false
      }
      return true
    }

    private static func saveMCPServer(
      _ payload: BridgeDesktopCommandPayload,
      auxiliary: WindowsAuxiliaryRuntime
    ) -> Bool {
      guard let name = BridgeDesktopCommandValue.nonEmpty(payload.name),
        let transport = BridgeDesktopCommandValue.nonEmpty(payload.mcpTransport),
        transport == "stdio" || transport == "http",
        let scope = mcpScope(payload)
      else { return true }
      let command = BridgeDesktopCommandValue.nonEmpty(payload.mcpCommand)
      let url = BridgeDesktopCommandValue.nonEmpty(payload.mcpURL)
      guard transport != "stdio" || command != nil, transport != "http" || url != nil else {
        return true
      }
      let id =
        BridgeDesktopCommandValue.nonEmpty(payload.mcpServerID)
        ?? UUID().uuidString.lowercased()
      let environment = (payload.mcpEnvironmentSecrets ?? []).map {
        IPCDeepSeekHarnessMCPSecretInput(name: $0.name, value: $0.value)
      }
      let headers = (payload.mcpHeaderSecrets ?? []).map {
        IPCDeepSeekHarnessMCPSecretInput(name: $0.name, value: $0.value)
      }
      let request = IPCDeepSeekHarnessMCPServerInput(
        id: id,
        name: name,
        enabled: payload.enabled ?? true,
        transport: transport,
        command: transport == "stdio" ? command : nil,
        args: transport == "stdio" ? payload.arguments ?? [] : [],
        url: transport == "http" ? url : nil,
        environment: environment,
        headers: headers,
        scope: scope
      )
      Task { @MainActor in await auxiliary.connections.saveDeepSeekHarnessMCPServer(request) }
      return true
    }

    private static func mcpScope(_ payload: BridgeDesktopCommandPayload) -> String? {
      let value =
        BridgeDesktopCommandValue.nonEmpty(payload.mcpServerScope)
        ?? BridgeDesktopAgentMCPScope.deepSeekHarness.rawValue
      return BridgeDesktopAgentMCPScope(rawValue: value)?.rawValue
    }
  }
#endif
