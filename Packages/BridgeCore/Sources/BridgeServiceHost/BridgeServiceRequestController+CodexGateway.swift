import BridgeIPC
import BridgeServiceCore
import Foundation

extension BridgeServiceRequestController {
  func handleExportCodexGatewayCredential(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      IPCCodexGatewayCredentialRequest.self, from: request)
    guard let applications = await composition.providerGateway.externalApplications else {
      throw ServiceStoreError.invalidArgument("external_application.codex_gateway")
    }
    let token = try await applications.codexGatewayCredential(clientID: payload.clientID)
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID, payload: IPCCodexGatewayCredentialResponse(token: token))
  }
}
