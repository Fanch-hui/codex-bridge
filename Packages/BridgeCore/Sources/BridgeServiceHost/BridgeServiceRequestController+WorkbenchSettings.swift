import BridgeIPC
import Foundation

extension BridgeServiceRequestController {
  func handleWorkbenchSettings(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let result: IPCWorkbenchSettings
    switch request.operation {
    case .getWorkbenchSettings:
      result = try await composition.embeddedDSH.workbenchSettings()
    case .setWorkbenchEnabled:
      let payload = try BridgeServiceIPCCodec.payload(IPCWorkbenchSettings.self, from: request)
      result = try await composition.embeddedDSH.setWorkbenchEnabled(payload.enabled)
    default:
      throw BridgeServiceIPCCodecError.invalidMessage
    }
    return try BridgeServiceIPCCodec.success(requestID: request.requestID, payload: result)
  }
}
