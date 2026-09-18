#if os(Windows)
  import BridgeDesktopUI

  extension WindowsWorkbenchModel {
    func recordWorkbenchCommandReceipt(
      requestID: String?,
      command: String,
      taskID: String?,
      input: String?,
      accepted: Bool,
      message: String? = nil
    ) {
      guard let requestID, !requestID.isEmpty else { return }
      if !accepted { errorMessage = message }
      workbenchCommandReceipt = BridgeDesktopWorkbenchCommandAck.receipt(
        requestID: requestID,
        command: command,
        taskID: taskID,
        input: input,
        accepted: accepted,
        message: message
      )
      publishDisplay()
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
  }
#endif
