import BridgeIPC
import Foundation

extension BridgeServiceRequestController {
  func handleAgentSetup(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let setup = composition.agentSetup
    switch request.operation {
    case .beginAgentSetup:
      let payload = try BridgeServiceIPCCodec.payload(IPCAgentSetupRequest.self, from: request)
      return try BridgeServiceIPCCodec.success(
        requestID: request.requestID, payload: await setup.begin(payload))
    case .continueAgentSetup:
      let payload = try BridgeServiceIPCCodec.payload(
        IPCAgentSetupContinueRequest.self, from: request)
      return try BridgeServiceIPCCodec.success(
        requestID: request.requestID, payload: await setup.resume(payload))
    case .cancelAgentSetup:
      let payload = try BridgeServiceIPCCodec.payload(IPCAgentSetupIDRequest.self, from: request)
      return try BridgeServiceIPCCodec.success(
        requestID: request.requestID, payload: await setup.cancel(payload.operationID))
    default:
      return try BridgeServiceIPCCodec.success(
        requestID: request.requestID, payload: await setup.snapshots())
    }
  }
}
