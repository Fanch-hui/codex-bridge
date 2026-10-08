#if os(Windows) || os(Linux)
  import BridgeDesktopUI
  import BridgeServiceAppCore

  extension WindowsWorkbenchModel {
    func recordWorkbenchCommandReceipt(
      requestID: String?,
      command: String,
      taskID: String?,
      input: String?,
      accepted: Bool,
      message: String? = nil,
      handoff: WorkbenchHandoffPreview? = nil,
      resultingTaskID: String? = nil,
      canEditInput: Bool? = nil
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
        handoff: handoff,
        resultingTaskID: resultingTaskID,
        canEditInput: canEditInput
      )
      publishDisplay()
    }

    func rejectWorkbenchCommand(
      requestID: String?,
      command: String,
      taskID: String?,
      input: String?,
      message: String,
      canEditInput: Bool? = nil
    ) {
      recordWorkbenchCommandReceipt(
        requestID: requestID,
        command: command,
        taskID: taskID,
        input: input,
        accepted: false,
        message: message,
        canEditInput: canEditInput
      )
    }
  }
#endif
