import BridgeIPC
import Foundation

extension BridgeServiceRequestController {
  func handleManageDeepSeekHarnessDesktop(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(
      DeepSeekHarnessDesktopRequest.self, from: request)
    let result = try await composition.application.serviceDeepSeekDesktop(
      installationID: payload.installationID, action: payload.action.rawValue, mode: payload.mode,
      projectID: payload.projectID, sessionID: payload.sessionID, taskID: payload.taskID,
      deadline: Self.deadline())
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: DeepSeekHarnessDesktopState(
        mode: result.mode, desktop: result.desktop,
        executablePath: result.executablePath, connectorInstalled: result.connectorInstalled,
        canInstallConnector: result.canInstallConnector))
  }
}
