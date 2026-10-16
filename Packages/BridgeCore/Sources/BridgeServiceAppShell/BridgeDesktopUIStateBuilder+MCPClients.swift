import BridgeDesktopUI
import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore

extension BridgeDesktopUIStateBuilder {
  private static let exposureOptions = [
    BridgeDesktopChoice(id: MCPServiceExposureMode.readOnly.rawValue, title: "只读"),
    BridgeDesktopChoice(id: MCPServiceExposureMode.full.rawValue, title: "完整"),
  ]

  static func clientRows(
    from model: BridgeServiceAppModel
  ) -> [BridgeDesktopMCPClientRow] {
    let chat =
      model.mcpClients.first { $0.clientID == MCPClientID.chatGPT.rawValue }
      ?? IPCMCPClientStatus(
        clientID: MCPClientID.chatGPT.rawValue,
        displayName: "ChatGPT / OpenAI Tunnel",
        enabled: true,
        exposureMode: model.exposureMode,
        activeSessionCount: 0
      )
    let qwen =
      model.mcpClients.first { $0.clientID == MCPClientID.qwenStudio.rawValue }
      ?? IPCMCPClientStatus(
        clientID: MCPClientID.qwenStudio.rawValue,
        displayName: "Qwen Studio",
        enabled: false,
        exposureMode: .readOnly,
        activeSessionCount: 0
      )
    let gemini =
      model.mcpClients.first { $0.clientID == MCPClientID.gemini.rawValue }
      ?? IPCMCPClientStatus(
        clientID: MCPClientID.gemini.rawValue,
        displayName: "Gemini",
        enabled: false,
        exposureMode: .full,
        activeSessionCount: 0
      )
    let connected = model.connectionState == .connected
    return [chat, qwen, gemini].map { client in
      clientRow(client, connected: connected)
    }
  }

  private static func clientRow(
    _ client: IPCMCPClientStatus,
    connected: Bool
  ) -> BridgeDesktopMCPClientRow {
    let local =
      client.clientID == MCPClientID.qwenStudio.rawValue
      || client.clientID == MCPClientID.gemini.rawValue
    let canCopy =
      client.clientID != MCPClientID.gemini.rawValue
      || (try? GeminiLocalMCPCommand.command()) != nil
    return BridgeDesktopMCPClientRow(
      clientID: client.clientID,
      displayName: client.displayName,
      enabled: client.enabled,
      exposureMode: client.exposureMode.rawValue,
      exposureOptions: exposureOptions,
      activeSessionCount: client.activeSessionCount,
      lastConnectedAt: client.lastConnectedAt,
      canToggle: local && connected,
      canCopyConfiguration: local && connected && canCopy,
      canRotateCredential: local && connected
    )
  }

}
