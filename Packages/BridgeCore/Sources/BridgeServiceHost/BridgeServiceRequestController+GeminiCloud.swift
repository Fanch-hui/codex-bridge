import BridgeIPC
import Foundation

extension BridgeServiceRequestController {
  func handleGeminiCloud(_ request: BridgeServiceIPCRequest) async throws -> Data {
    switch request.operation {
    case .getGeminiCloudStatus:
      return try BridgeServiceIPCCodec.success(
        requestID: request.requestID, payload: await composition.geminiCloudStatus())
    case .configureGeminiCloud:
      let value = try BridgeServiceIPCCodec.payload(IPCGeminiCloudConfiguration.self, from: request)
      return try BridgeServiceIPCCodec.success(
        requestID: request.requestID, payload: await composition.configureGeminiCloud(value))
    case .exportGeminiCloudConfiguration:
      let value = try BridgeServiceIPCCodec.payload(IPCGeminiCloudExportRequest.self, from: request)
      let configuration = try await composition.exportGeminiCloudConfiguration(kind: value.kind)
      return try BridgeServiceIPCCodec.success(
        requestID: request.requestID,
        payload: IPCMCPClientConfigurationExport(configurationJSON: configuration))
    default:
      preconditionFailure("Invalid Gemini cloud operation")
    }
  }
}
