import BridgeIPC
import Foundation

extension BridgeServiceRequestController {
  func handlePrepareAppUpdate(_ request: BridgeServiceIPCRequest) async throws -> Data {
    guard request.payload == nil else {
      throw BridgeServiceIPCCodecError.invalidMessage
    }
    let canInstall = try await composition.application.prepareAppUpdate()
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCAppUpdatePreparationResponse(canInstall: canInstall)
    )
  }

  func handleCancelAppUpdate(_ request: BridgeServiceIPCRequest) async throws -> Data {
    guard request.payload == nil else {
      throw BridgeServiceIPCCodecError.invalidMessage
    }
    try await composition.application.cancelAppUpdate()
    return try BridgeServiceIPCCodec.emptySuccess(requestID: request.requestID)
  }
}
