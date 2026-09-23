import BridgeIPC
import BridgeMCP
import Foundation

extension BridgeServiceRequestController {
  func handleTaskHandoff(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(MCPTaskHandoffRequest.self, from: request)
    let result = try await composition.application.serviceTaskHandoff(
      payload, deadline: ContinuousClock.now.advanced(by: .seconds(30)))
    return try BridgeServiceIPCCodec.success(requestID: request.requestID, payload: result)
  }
}
