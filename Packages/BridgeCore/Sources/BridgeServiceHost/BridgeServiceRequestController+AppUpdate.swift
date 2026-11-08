import BridgeIPC
import Foundation

extension BridgeServiceRequestController {
  func handlePrepareAppUpdate(_ request: BridgeServiceIPCRequest) async throws -> Data {
    guard request.payload == nil else {
      throw BridgeServiceIPCCodecError.invalidMessage
    }
    let status = try await composition.application.prepareAppUpdateStatus()
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCAppUpdatePreparationResponse(
        canInstall: status.canInstall, waitingReason: status.waitingReason,
        blockers: status.blockers.map {
          IPCAppUpdateBlocker(kind: $0.kind, id: $0.id, projectID: $0.projectID, label: $0.label)
        })
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
