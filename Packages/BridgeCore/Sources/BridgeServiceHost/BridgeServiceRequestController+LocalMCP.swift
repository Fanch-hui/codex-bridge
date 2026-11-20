import BridgeIPC
import BridgeMCP
import Foundation

extension BridgeServiceRequestController {
  func handleGetLocalMCPConnection(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(IPCMCPClientRequest.self, from: request)
    guard
      payload.clientID == MCPClientID.gemini.rawValue
        || ServiceExternalMCPClient.isValidID(payload.clientID)
    else {
      throw ServiceMCPClientRegistryError.unsupportedClient
    }
    let clientID = MCPClientID(rawValue: payload.clientID)
    let endpoint = try await composition.startLocalMCP()
    let token = try await composition.mcpClients.credential(for: clientID)
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCLocalMCPConnectionResponse(
        localMCPURL: endpoint.localURL.absoluteString, token: token
      )
    )
  }
}
