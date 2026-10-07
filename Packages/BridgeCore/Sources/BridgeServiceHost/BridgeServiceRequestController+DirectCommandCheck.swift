import BridgeIPC
import BridgeServiceCore
import Foundation

extension BridgeServiceRequestController {
  func handleCheckDirectCommand(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let input = try BridgeServiceIPCCodec.payload(IPCDirectCommandCheckRequest.self, from: request)
    guard !input.requestID.isEmpty, input.requestID.utf8.count <= 128 else {
      throw ServiceStoreError.invalidArgument("direct.requestID")
    }
    let result = try await composition.application.serviceCheckDirectCommand(
      projectID: input.projectID, commandLine: input.commandLine,
      workingDirectory: input.workingDirectory, deadline: Self.deadline())
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCDirectCommandCheckResult(
        projectID: input.projectID, requestID: input.requestID,
        allowed: result.allowed, code: result.code, message: result.message,
        matchedRule: result.matchedRule, ruleSource: result.ruleSource,
        executable: result.executable, workingDirectory: result.workingDirectory,
        requiresApproval: result.requiresApproval, nextAction: result.nextAction))
  }
}
