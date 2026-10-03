import BridgeIPC
import BridgeMCP
import BridgeServiceApplication
import Foundation

extension BridgeServiceRequestController {
  func handleManageAgentNativeSessionDirectory(
    _ request: BridgeServiceIPCRequest
  ) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      MCPNativeSessionDirectoryRequest.self, from: request)
    let response = try await composition.application.serviceNativeSessionDirectory(
      payload, deadline: Self.deadline())
    return try BridgeServiceIPCCodec.success(requestID: request.requestID, payload: response)
  }
}
