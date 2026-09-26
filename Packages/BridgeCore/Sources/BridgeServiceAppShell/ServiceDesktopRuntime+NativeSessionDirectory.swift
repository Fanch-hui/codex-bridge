import BridgeAgentCore
import BridgeDesktopUI
import BridgeIPC
import BridgeMCP
import BridgeServiceAppCore
import Foundation

extension BridgeServiceAppModel {
  func continueNativeAgentSession(
    projectID: String,
    providerID: String,
    installationID: String,
    sessionID: String,
    prompt: String,
    requestID: String
  ) {
    let request = IPCAgentSubmitRequest(
      projectID: projectID, providerID: providerID, installationID: installationID,
      permissionMode: workbenchPermissionMode, prompt: prompt, threadID: sessionID,
      networkAccess: false, permissionModeOverride: true, clientRequestID: requestID)
    runWorkbenchMutation(
      requestID: requestID, command: BridgeDesktopCommand.continueNativeAgentSession.rawValue,
      taskID: nil, input: prompt
    ) { [weak self] client in
      guard let self else { return false }
      let response = try await client.submitAgentTask(request)
      await self.refresh(silent: true, includeCatalog: false)
      self.openTask(response.taskID)
      self.postToast("已续写原生会话")
      return true
    }
  }

  func manageNativeSessionDirectory(_ request: MCPNativeSessionDirectoryRequest) {
    nativeSessionDirectoryGeneration &+= 1
    let generation = nativeSessionDirectoryGeneration
    nativeSessionDirectory = updatedState(
      from: nativeSessionDirectory, request: request, isLoading: true,
      status: "正在读取原生会话…", error: nil)
    Task { [weak self] in
      guard let self else { return }
      do {
        let client = try currentClient()
        let response = try await client.manageAgentNativeSessionDirectory(request)
        guard nativeSessionDirectoryGeneration == generation else { return }
        if request.operation == .index || request.operation == .rename
          || request.operation == .delete
        {
          let refresh = MCPNativeSessionDirectoryRequest(
            operation: .list, projectID: request.projectID,
            installationID: request.installationID, offset: 0, limit: 50)
          let page = try await client.manageAgentNativeSessionDirectory(refresh).page
          guard let page else { throw BridgeServiceClientError.unavailable }
          applyNativeSessionResponse(
            .init(page: page), request: refresh,
            status: nativeSessionSuccessMessage(request.operation),
            deletingSessionID: request.operation == .delete ? request.sessionID : nil,
            generation: generation)
        } else {
          applyNativeSessionResponse(
            response, request: request, status: nil, generation: generation)
        }
      } catch {
        guard nativeSessionDirectoryGeneration == generation else { return }
        nativeSessionDirectory = updatedState(
          from: nativeSessionDirectory, request: request, isLoading: false,
          status: nil, error: BridgeServiceErrorMessage.message(error))
      }
    }
  }

  private func applyNativeSessionResponse(
    _ response: MCPNativeSessionDirectoryResponse,
    request: MCPNativeSessionDirectoryRequest,
    status: String?,
    deletingSessionID: String? = nil,
    generation: UInt64
  ) {
    guard nativeSessionDirectoryGeneration == generation else { return }
    let prior = nativeSessionDirectory
    let sessions: [AgentNativeSessionSummary]
    if let page = response.page {
      sessions = request.offset == 0 ? page.sessions : (prior?.sessions ?? []) + page.sessions
    } else {
      sessions = prior?.sessions ?? []
    }
    let deletedSelection = deletingSessionID != nil && deletingSessionID == prior?.selectedSessionID
    let transcript: [AgentNativeSessionMessage]
    if let page = response.transcript {
      transcript = request.offset == 0 ? page.messages : (prior?.transcript ?? []) + page.messages
    } else if deletedSelection {
      transcript = []
    } else {
      transcript = prior?.transcript ?? []
    }
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
      isOpen: true, statusMessage: status, errorMessage: nil)
  }

  private func updatedState(
    from prior: BridgeDesktopNativeSessionDirectoryState?,
    request: MCPNativeSessionDirectoryRequest,
    isLoading: Bool,
    status: String?,
    error: String?
  ) -> BridgeDesktopNativeSessionDirectoryState {
    let sameScope =
      prior?.projectID == request.projectID
      && prior?.installationID == request.installationID
    let sameSelection = request.operation != .read || request.sessionID == prior?.selectedSessionID
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
  }

  private func nativeSessionSuccessMessage(_ operation: MCPNativeSessionDirectoryOperation)
    -> String
  {
    switch operation {
    case .index: "原生会话已导入，可在续写时选择。"
    case .rename: "原生会话名称已更新。"
    case .delete: "原生会话已删除。"
    case .list, .read: ""
    }
  }
}
