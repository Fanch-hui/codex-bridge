#if os(Windows)
  import BridgeAgentCore
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeMCP
  import BridgeServiceAppCore

  extension WindowsWorkbenchModel {
    func continueNativeAgentSession(
      projectID: String,
      providerID: String,
      installationID: String,
      sessionID: String,
      prompt: String
    ) async {
      let request = IPCAgentSubmitRequest(
        projectID: projectID, providerID: providerID, installationID: installationID,
        permissionMode: workbenchPermissionMode, prompt: prompt, threadID: sessionID,
        networkAccess: false, permissionModeOverride: true)
      do {
        let response = try await client.submitAgentTask(request)
        await refreshTasks()
        selectTask(id: response.taskID)
        feedback.postToast("已续写原生会话")
      } catch {
        feedback.postAlert(BridgeServiceErrorMessage.message(error))
      }
    }

    func manageNativeSessionDirectory(_ request: MCPNativeSessionDirectoryRequest) async {
      nativeSessionDirectoryGeneration &+= 1
      let generation = nativeSessionDirectoryGeneration
      nativeSessionDirectory = nativeSessionState(
        from: nativeSessionDirectory, request: request, isLoading: true,
        status: "正在读取原生会话…", error: nil)
      refreshDisplaySnapshot()
      do {
        let response = try await client.manageAgentNativeSessionDirectory(request)
        guard generation == nativeSessionDirectoryGeneration else { return }
        if request.operation == .index || request.operation == .rename
          || request.operation == .delete
        {
          let refresh = MCPNativeSessionDirectoryRequest(
            operation: .list, projectID: request.projectID,
            installationID: request.installationID)
          let page = try await client.manageAgentNativeSessionDirectory(refresh).page
          guard let page else { throw BridgeServiceClientError.unavailable }
          applyNativeSessionResponse(
            .init(page: page), request: refresh,
            status: successMessage(request.operation),
            deletingSessionID: request.operation == .delete ? request.sessionID : nil,
            generation: generation)
        } else {
          applyNativeSessionResponse(
            response, request: request, status: nil, generation: generation)
        }
      } catch {
        guard generation == nativeSessionDirectoryGeneration else { return }
        nativeSessionDirectory = nativeSessionState(
          from: nativeSessionDirectory, request: request, isLoading: false,
          status: nil, error: BridgeServiceErrorMessage.message(error))
      }
      refreshDisplaySnapshot()
    }

    private func applyNativeSessionResponse(
      _ response: MCPNativeSessionDirectoryResponse,
      request: MCPNativeSessionDirectoryRequest,
      status: String?,
      deletingSessionID: String? = nil,
      generation: UInt64
    ) {
      guard generation == nativeSessionDirectoryGeneration else { return }
      let prior = nativeSessionDirectory
      let sessions =
        response.page.map { page in
          request.offset == 0 ? page.sessions : (prior?.sessions ?? []) + page.sessions
        } ?? prior?.sessions ?? []
      let deletedSelection =
        deletingSessionID != nil && deletingSessionID == prior?.selectedSessionID
      let transcript =
        response.transcript.map { page in
          request.offset == 0 ? page.messages : (prior?.transcript ?? []) + page.messages
        } ?? (deletedSelection ? [] : (prior?.transcript ?? []))
      let nextOffset: Int?
      if let page = response.page {
        nextOffset = page.nextOffset
      } else {
        nextOffset = prior?.nextOffset
      }
      let transcriptNextOffset: Int?
      if let page = response.transcript {
        transcriptNextOffset = page.nextOffset
      } else {
        transcriptNextOffset = deletedSelection ? nil : prior?.transcriptNextOffset
      }
      nativeSessionDirectory = BridgeDesktopNativeSessionDirectoryState(
        installations: prior?.installations ?? [],
        projectID: request.projectID, installationID: request.installationID,
        selectedSessionID: deletedSelection ? nil : (request.sessionID ?? prior?.selectedSessionID),
        sessions: sessions, transcript: transcript,
        nextOffset: nextOffset, transcriptNextOffset: transcriptNextOffset,
        isOpen: true, statusMessage: status)
    }

    private func nativeSessionState(
      from prior: BridgeDesktopNativeSessionDirectoryState?,
      request: MCPNativeSessionDirectoryRequest,
      isLoading: Bool,
      status: String?,
      error: String?
    ) -> BridgeDesktopNativeSessionDirectoryState {
      let sameScope =
        prior?.projectID == request.projectID
        && prior?.installationID == request.installationID
      let sameSelection =
        request.operation != .read || request.sessionID == prior?.selectedSessionID
      return BridgeDesktopNativeSessionDirectoryState(
        installations: prior?.installations ?? [],
        projectID: request.projectID, installationID: request.installationID,
        selectedSessionID: request.sessionID ?? (sameScope ? prior?.selectedSessionID : nil),
        sessions: sameScope ? (prior?.sessions ?? []) : [],
        transcript: sameScope && sameSelection ? (prior?.transcript ?? []) : [],
        nextOffset: sameScope ? prior?.nextOffset : nil,
        transcriptNextOffset: sameScope && sameSelection ? prior?.transcriptNextOffset : nil,
        isOpen: true, isLoading: isLoading, statusMessage: status, errorMessage: error)
    }

    func closeNativeSessionDirectory() {
      guard let prior = nativeSessionDirectory else { return }
      nativeSessionDirectory = BridgeDesktopNativeSessionDirectoryState(
        installations: prior.installations,
        projectID: prior.projectID, installationID: prior.installationID,
        selectedSessionID: prior.selectedSessionID, sessions: prior.sessions,
        transcript: prior.transcript, nextOffset: prior.nextOffset,
        transcriptNextOffset: prior.transcriptNextOffset, isOpen: false,
        statusMessage: prior.statusMessage, errorMessage: prior.errorMessage)
      refreshDisplaySnapshot()
    }

    private func successMessage(_ operation: MCPNativeSessionDirectoryOperation) -> String {
      switch operation {
      case .index: "原生会话已导入，可在续写时选择。"
      case .rename: "原生会话名称已更新。"
      case .delete: "原生会话已删除。"
      case .list, .read: ""
      }
    }
  }
#endif
