import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore
import Foundation

extension BridgeServiceAppModel {
  func handoffTask(
    _ task: MCPServiceTaskSnapshot, providerID: String, prompt: String, requestID: String?,
    action: String? = nil, handoffID: String? = nil, revision: String? = nil
  ) {
    guard let requestID, !requestID.isEmpty else { return }
    Task { [weak self] in
      guard let self else { return }
      do {
        let request = try WorkbenchHandoffClient.request(
          sourceTaskID: task.taskID, providerID: providerID, additionalInstructions: prompt,
          action: action, handoffID: handoffID, revision: revision)
        let response = try await self.currentClient().taskHandoff(request)
        if response.targetTaskID != nil {
          await self.refresh(silent: true, includeCatalog: false)
        }
        self.recordWorkbenchCommandReceipt(
          requestID: requestID, command: "handoffTask", taskID: task.taskID, input: prompt,
          accepted: true, message: response.message, handoff: response)
      } catch {
        self.rejectWorkbenchCommand(
          requestID: requestID, command: "handoffTask", taskID: task.taskID, input: prompt,
          message: BridgeServiceErrorMessage.message(error))
      }
    }
  }
}
