import BridgeIPC
import BridgeServiceApplication
import Foundation

extension BridgeServiceRequestController {
  func handleDeepSeekSearchConfiguration(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let configuration = ServiceDeepSeekSearchConfiguration(settings: composition.settings)
    let url: String?
    if request.operation == .saveDeepSeekSearchConfiguration {
      let payload = try BridgeServiceIPCCodec.payload(
        IPCDeepSeekSearchConfiguration.self, from: request)
      url = try await configuration.save(baseURL: payload.baseURL)
    } else {
      url = try await configuration.baseURL()
    }
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID, payload: IPCDeepSeekSearchConfiguration(baseURL: url))
  }
}
