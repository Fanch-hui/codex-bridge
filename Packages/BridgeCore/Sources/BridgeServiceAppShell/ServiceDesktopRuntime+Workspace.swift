import BridgeDesktopUI
import BridgeIPC
import BridgeServiceAppCore

extension BridgeServiceAppModel {
  func performWorkbenchWorkspace(_ envelope: BridgeDesktopCommandEnvelope) {
    // Bind the answer to the selected project first so even a rejection is acknowledged by the page.
    workspaceModel.selectProject(selectedProjectID)
    guard connectionState == .connected else {
      workspaceModel.rejectUnavailable(requestID: envelope.requestID)
      return
    }
    let request: IPCWorkbenchWorkspaceRequest
    do {
      let payload = envelope.payload
      request = try WorkbenchWorkspaceRequestBuilder.request(
        action: payload.action, projectID: payload.projectID,
        selectedProjectID: selectedProjectID, registeredProjectIDs: Set(projects.map(\.projectID)),
        path: payload.path, cursor: payload.value, offset: payload.offset, limit: payload.limit,
        content: payload.input, expectedSHA256: payload.messageKey,
        operationID: payload.operationID,
        clientRequestID: envelope.requestID, confirmed: payload.confirmed ?? false)
    } catch {
      workspaceModel.reject(requestID: envelope.requestID, message: Self.message(error))
      return
    }
    Task { [weak self] in
      guard let self else { return }
      await self.workspaceModel.perform(request)
      if request.action == .applyWrite {
        await self.refresh(silent: true, includeCatalog: false)
      }
    }
  }
}
