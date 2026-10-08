#if os(Windows) || os(Linux)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeServiceAppCore

  extension WindowsWorkbenchModel {
    func performWorkbenchWorkspace(_ envelope: BridgeDesktopCommandEnvelope) async {
      guard connectionState == .connected, !isShuttingDown else {
        workspaceModel.reject(
          requestID: envelope.requestID, message: "后台 Service 未连接，无法操作项目文件。")
        return
      }
      let payload = envelope.payload
      let request: IPCWorkbenchWorkspaceRequest
      do {
        request = try WorkbenchWorkspaceRequestBuilder.request(
          action: payload.action,
          projectID: payload.projectID,
          selectedProjectID: selectedProjectID,
          registeredProjectIDs: Set(projects.map(\.projectID)),
          path: payload.path,
          cursor: payload.value,
          offset: payload.offset,
          limit: payload.limit,
          content: payload.input,
          expectedSHA256: payload.messageKey,
          operationID: payload.operationID,
          clientRequestID: envelope.requestID,
          confirmed: payload.confirmed ?? false)
      } catch {
        workspaceModel.reject(
          requestID: envelope.requestID, message: BridgeServiceErrorMessage.message(error))
        return
      }
      await workspaceModel.perform(request)
      if request.action == .applyWrite { await refreshApprovals() }
    }
  }
#endif
