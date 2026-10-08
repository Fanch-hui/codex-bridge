import BridgeDesktopUI
import BridgeIPC
import BridgeServiceAppCore
import Foundation

extension BridgeServiceAppModel {
  func submitDSHTask(_ envelope: BridgeDesktopCommandEnvelope) {
    let payload = envelope.payload
    let request: IPCAgentSubmitRequest
    do {
      guard connectionState == .connected else { throw BridgeServiceClientError.unavailable }
      request = try DSHWorkbenchTaskSubmission.request(
        projectID: payload.projectID,
        installationID: payload.installationID,
        prompt: payload.input,
        model: payload.modelID,
        effort: payload.effort,
        skillNames: payload.skillNames,
        attachmentPaths: payload.attachmentPaths,
        permissionMode: payload.permissionMode ?? "full",
        clientRequestID: envelope.requestID,
        queueIfBusy: payload.queueIfBusy ?? false,
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
        canEditInput: true
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
