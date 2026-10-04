import BridgeIPC
import BridgeServiceCore
import Foundation

extension BridgeServiceRequestController {
  func handleDirectConfiguration(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let saved: ServiceDirectConfiguration?
    if request.operation == .updateDirectConfiguration {
      let input = try BridgeServiceIPCCodec.payload(IPCDirectConfiguration.self, from: request)
      guard let mode = ServiceDirectCommandMode(rawValue: input.commandMode) else {
        throw ServiceStoreError.invalidArgument("direct.commandMode")
      }
      saved = try await composition.application.serviceUpdateDirectConfiguration(
        ServiceDirectConfiguration(
          commandMode: mode, allowedCommands: input.allowedCommands,
          deniedCommands: input.deniedCommands),
        deadline: Self.deadline()
      )
    } else {
      saved = try await composition.application.serviceDirectConfiguration(
        deadline: Self.deadline())
    }
    let configuration = saved ?? ServiceDirectConfiguration()
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCDirectConfiguration(
        commandMode: configuration.commandMode.rawValue,
        allowedCommands: configuration.allowedCommands,
        deniedCommands: configuration.deniedCommands, usesProjectDefaults: saved == nil
      ))
  }
}
