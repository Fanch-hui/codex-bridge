import BridgeIPC
import BridgeMCP
import Foundation

extension BridgeServiceRequestController {
  func handleGetLocalMCPConnection(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(IPCMCPClientRequest.self, from: request)
    guard payload.clientID == MCPClientID.gemini.rawValue else {
      throw ServiceMCPClientRegistryError.unsupportedClient
    }
    let connection = try await composition.localMCPConnection(clientID: .gemini)
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCLocalMCPConnectionResponse(
        localMCPURL: connection.url.absoluteString, token: connection.token
      )
    )
  }
}
