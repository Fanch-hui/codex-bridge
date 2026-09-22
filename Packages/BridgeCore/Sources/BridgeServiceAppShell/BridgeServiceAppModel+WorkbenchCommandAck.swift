import BridgeDesktopUI
import BridgeServiceAppCore
import Foundation

extension BridgeServiceAppModel {
  func recordWorkbenchCommandReceipt(
    requestID: String?,
    command: String,
    taskID: String?,
    input: String?,
    accepted: Bool,
    message: String? = nil,
    handoff: WorkbenchHandoffPreview? = nil
  ) {
    guard let requestID, !requestID.isEmpty else { return }
    if !accepted { errorMessage = message }
    workbenchCommandReceipt = BridgeDesktopWorkbenchCommandAck.receipt(
      requestID: requestID,
      command: command,
      taskID: taskID,
      input: input,
      accepted: accepted,
      message: message,
      handoff: handoff
    )
  }

  func rejectWorkbenchCommand(
    requestID: String?,
    command: String,
    taskID: String?,
    input: String?,
    message: String
  ) {
    recordWorkbenchCommandReceipt(
      requestID: requestID,
      command: command,
      taskID: taskID,
      input: input,
      accepted: false,
      message: message
    )
  }

  func runWorkbenchMutation(
    requestID: String?,
    command: String,
    taskID: String?,
    input: String?,
    operation: @escaping @MainActor @Sendable (any BridgeServiceClientProtocol) async throws -> Bool
  ) {
    guard let requestID, !requestID.isEmpty else {
      runMutation { client in _ = try await operation(client) }
      return
    }
    errorMessage = nil
    Task { [weak self] in
      guard let self else { return }
      do {
        let accepted = try await operation(try self.currentClient())
        let message = accepted ? nil : "本机 Service 未接受这次任务操作。"
        self.recordWorkbenchCommandReceipt(
          requestID: requestID,
          command: command,
          taskID: taskID,
          input: input,
          accepted: accepted,
          message: message
        )
      } catch {
        let message = Self.message(error)
        self.errorMessage = message
        self.recordWorkbenchCommandReceipt(
          requestID: requestID,
          command: command,
          taskID: taskID,
          input: input,
          accepted: false,
          message: message
        )
      }
    }
  }
}
