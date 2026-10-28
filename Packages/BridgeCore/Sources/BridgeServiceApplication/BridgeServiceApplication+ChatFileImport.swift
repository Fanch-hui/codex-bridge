import BridgeDomain
import BridgeMCP
import BridgeSecurity
import Foundation

struct ChatFileImportCacheEntry {
  let transferID: String
  let expiresAt: Date
}

extension BridgeServiceApplication {
  public func serviceImportChatFile(
    _ request: MCPChatFileImportRequest, invocationContext: MCPInvocationContext,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectWriteReceipt {
    try await importChatFile(
      request, invocationContext: invocationContext, deadline: deadline,
      download: { url, deadline in
        try await ChatAttachmentDownload.run(url: url, deadline: deadline)
      })
  }

  func importChatFile(
    _ request: MCPChatFileImportRequest, invocationContext: MCPInvocationContext,
    deadline: ContinuousClock.Instant,
    download: @Sendable (URL, ContinuousClock.Instant) async throws -> Data
  ) async throws -> MCPDirectWriteReceipt {
    try Self.checkDeadline(deadline)
    guard invocationContext.clientID == .chatGPT else {
      throw MCPChatFileImportError.unsupportedSource
    }
    let url = try ChatAttachmentDownload.validatedURL(request.file.downloadURL)
    _ = try await writableProject(request.projectID)
    do {
      try await mutations.validateTransferPath(
        projectID: ProjectID(rawValue: request.projectID), relativePath: request.relativePath)
    } catch { throw Self.publicMutationError(error) }
    guard !request.file.fileID.isEmpty, request.file.fileID.utf8.count <= 512,
      request.mode == "create" || request.mode == "replace",
      request.expectedSHA256.map(ServiceFileUploadStore.isDigest) ?? true,
      request.mode != "replace" || request.expectedSHA256 != nil
    else { throw BridgeMCPQueryError.contractRejected }
    let key = DirectActionApprovalCenter.payloadDigest(
      ChatFileImportIdentity(request: request, clientID: invocationContext.clientID.rawValue))
    chatFileImports = chatFileImports.filter { $0.value.expiresAt > Date() }
    if let entry = chatFileImports[key] {
      return try await serviceCommitFileUpload(
        transferID: entry.transferID, clientRequestID: key,
        invocationContext: invocationContext, deadline: deadline)
    }
    guard !chatFileImportDownloads.contains(key), chatFileImportDownloads.count < 2,
      chatFileImports.count + chatFileImportDownloads.count < 32
    else { throw BridgeMCPQueryError.busy }
    chatFileImportDownloads.insert(key)
    defer { chatFileImportDownloads.remove(key) }
    let content = try await download(url, deadline)
    try Self.checkDeadline(deadline)
    guard content.count <= MCPFileTransferLimits.maximumFileBytes else {
      throw MCPChatFileImportError.fileTooLarge
    }
    let transfer = try await stageChatFile(
      request, content: content, invocationContext: invocationContext, deadline: deadline)
    chatFileImports[key] = ChatFileImportCacheEntry(
      transferID: transfer.transferID, expiresAt: Date().addingTimeInterval(15 * 60))
    return try await serviceCommitFileUpload(
      transferID: transfer.transferID, clientRequestID: key,
      invocationContext: invocationContext, deadline: deadline)
  }

  private func stageChatFile(
    _ request: MCPChatFileImportRequest, content: Data,
    invocationContext: MCPInvocationContext, deadline: ContinuousClock.Instant
  ) async throws -> MCPFileTransfer {
    let transfer = try await serviceBeginFileUpload(
      MCPFileUploadRequest(
        projectID: request.projectID, relativePath: request.relativePath, byteCount: content.count,
        sha256: SecureFileRevision.digest(of: content).sha256, mode: request.mode,
        expectedSHA256: request.expectedSHA256, createParents: request.createParents),
      invocationContext: invocationContext, deadline: deadline)
    do {
      var offset = 0
      while offset < content.count {
        try Self.checkDeadline(deadline)
        try Task.checkCancellation()
        let end = min(content.count, offset + MCPFileTransferLimits.maximumChunkBytes)
        _ = try await fileUploads.append(
          transfer.transferID, owner: invocationContext.clientID, offset: offset,
          data: content.subdata(in: offset..<end))
        offset = end
      }
      return transfer
    } catch {
      _ = try? await fileUploads.cancel(transfer.transferID, owner: invocationContext.clientID)
      throw error
    }
  }
}

private struct ChatFileImportIdentity: Encodable {
  let clientID: String
  let sourceDigest: String
  let projectID: String
  let relativePath: String
  let mode: String
  let expectedSHA256: String?
  let createParents: Bool
  let clientRequestID: String?

  init(request: MCPChatFileImportRequest, clientID: String) {
    self.clientID = clientID
    sourceDigest = SecureFileRevision.digest(of: Data(request.file.fileID.utf8)).sha256
    projectID = request.projectID
    relativePath = request.relativePath
    mode = request.mode
    expectedSHA256 = request.expectedSHA256
    createParents = request.createParents
    clientRequestID = request.clientRequestID
  }
}
