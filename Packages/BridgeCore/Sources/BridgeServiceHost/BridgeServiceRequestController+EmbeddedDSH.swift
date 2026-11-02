import BridgeIPC
import Foundation

extension BridgeServiceRequestController {
  func handleEmbeddedDSH(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(IPCEmbeddedDSHRequest.self, from: request)
    let result = try await composition.embeddedDSH.call(payload)
    return try BridgeServiceIPCCodec.success(requestID: request.requestID, payload: result)
  }
}
