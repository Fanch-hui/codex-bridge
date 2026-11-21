import BridgeDomain
import BridgeIPC
import BridgeServiceCore
import BridgeSkills
import Foundation

extension BridgeServiceRequestController {
  func handleSkillHub(_ request: BridgeServiceIPCRequest) async throws -> Data {
    let payload = try BridgeServiceIPCCodec.payload(IPCSkillHubRequest.self, from: request)
    guard payload.payloadJSON.utf8.count <= 512 * 1_024,
      let payloadData = payload.payloadJSON.data(using: .utf8)
    else {
      throw ServiceStoreError.invalidArgument("skill_hub.payload")
    }
    guard let skillHub = composition.application.skillHub else {
      throw SkillHubError.operationFailed("技能中心服务暂不可用。")
    }
    let application = composition.application
    let resultData = try await skillHub.handleAction(
      payload.action,
      payloadData: payloadData,
      resolveProject: { projectID in try await application.skillProjectRoot(projectID) }
    )
    return try BridgeServiceIPCCodec.success(
      requestID: request.requestID,
      payload: IPCSkillHubResponse(resultJSON: String(decoding: resultData, as: UTF8.self))
    )
  }
}
