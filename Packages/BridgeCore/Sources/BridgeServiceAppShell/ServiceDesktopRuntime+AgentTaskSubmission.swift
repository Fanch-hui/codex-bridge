import BridgeDesktopUI
import BridgeIPC
import BridgeServiceAppCore
import Foundation

extension BridgeServiceAppModel {
  /// Starts a task for the Agent the user picked in the web workbench inspector.
  func submitAgentTask(_ envelope: BridgeDesktopCommandEnvelope) {
    let payload = envelope.payload
    let request: IPCAgentSubmitRequest
    do {
      guard connectionState == .connected else { throw BridgeServiceClientError.unavailable }
      request = try WorkbenchAgentTaskSubmission.request(
        projectID: payload.projectID,
        providerID: payload.providerID,
        installationID: payload.installationID,
        prompt: payload.input,
        model: payload.modelID,
        effort: payload.effort,
        permissionMode: payload.permissionMode,
        clientRequestID: envelope.requestID,
        registeredProjectIDs: Set(projects.map(\.projectID)),
        installations: agentInstallations
      )
    } catch {
      rejectWorkbenchCommand(
        requestID: envelope.requestID,
        command: envelope.command.rawValue,
        taskID: nil,
        input: payload.input,
        message: Self.message(error),
        canEditInput: WorkbenchAgentTaskSubmission.canEditInput(after: error)
      )
      return
    }
    runWorkbenchMutation(
      requestID: envelope.requestID,
      command: envelope.command.rawValue,
      taskID: nil,
      input: payload.input
    ) { [weak self] client in
      guard let self else { return (false, nil) }
      let response = try await client.submitAgentTask(request)
      await self.refresh(silent: true, includeCatalog: false)
      self.openTask(response.taskID)
      self.selection = .workbench
      return (true, response.taskID)
    }
  }
}
