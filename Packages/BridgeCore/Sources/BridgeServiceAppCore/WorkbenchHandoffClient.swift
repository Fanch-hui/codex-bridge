import BridgeIPC
import BridgeMCP
import Foundation

public typealias WorkbenchHandoffPreview = MCPTaskHandoffPreview

public enum WorkbenchHandoffClient {
  public static func request(
    sourceTaskID: String, providerID: String, additionalInstructions: String,
    action: String?, handoffID: String?, revision: String?
  ) throws -> MCPTaskHandoffRequest {
    guard let action, let operation = MCPTaskHandoffRequest.Action(rawValue: action),
      let handoffID, !handoffID.isEmpty,
      operation != .submit || revision?.isEmpty == false
    else { throw BridgeServiceClientError.serviceRestartRequired }
    return MCPTaskHandoffRequest(
      action: operation, sourceTaskID: sourceTaskID, providerID: providerID,
      handoffID: handoffID, additionalInstructions: additionalInstructions,
      expectedRevision: revision)
  }
}
