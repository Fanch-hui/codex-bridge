#if os(Windows)
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore
  import Foundation

  extension WindowsWorkbenchModel {
    func handoffTask(
      id: String, providerID: String, prompt: String, requestID: String?,
      action: String? = nil, handoffID: String? = nil, revision: String? = nil
    ) async {
      guard let requestID, !requestID.isEmpty else { return }
      do {
        guard connectionState == .connected else { throw BridgeServiceClientError.unavailable }
        let request = try WorkbenchHandoffClient.request(
          sourceTaskID: id, providerID: providerID, additionalInstructions: prompt,
          action: action, handoffID: handoffID, revision: revision)
        let response = try await client.taskHandoff(request)
        if response.targetTaskID != nil { await refreshTasks() }
        recordWorkbenchCommandReceipt(
          requestID: requestID, command: "handoffTask", taskID: id, input: prompt,
          accepted: true, message: response.message, handoff: response)
      } catch {
        rejectWorkbenchCommand(
          requestID: requestID, command: "handoffTask", taskID: id, input: prompt,
          message: BridgeServiceErrorMessage.message(error))
      }
    }
  }
#endif
