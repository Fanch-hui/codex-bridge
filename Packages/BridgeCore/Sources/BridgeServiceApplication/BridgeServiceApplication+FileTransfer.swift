import BridgeDomain
import BridgeFiles
import BridgeMCP
import BridgeSecurity
import Foundation

extension BridgeServiceApplication {
  public func serviceBeginFileUpload(
    _ request: MCPFileUploadRequest, invocationContext: MCPInvocationContext,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPFileTransfer {
    try Self.checkDeadline(deadline)
    _ = try await writableProject(request.projectID)
    do {
      try await mutations.validateTransferPath(
        projectID: ProjectID(rawValue: request.projectID), relativePath: request.relativePath)
      return try await fileUploads.begin(request, owner: invocationContext.clientID)
    } catch let error as ProjectMutationError {
      throw Self.publicMutationError(error)
    }
  }

  public func serviceAppendFileUpload(
    transferID: String, offset: Int, dataBase64: String,
    invocationContext: MCPInvocationContext, deadline: ContinuousClock.Instant
  ) async throws -> MCPFileTransfer {
    try Self.checkDeadline(deadline)
    guard dataBase64.utf8.count <= MCPFileTransferLimits.maximumBase64Bytes,
      let data = Data(base64Encoded: dataBase64), data.base64EncodedString() == dataBase64
    else { throw BridgeMCPQueryError.contractRejected }
    return try await fileUploads.append(
      transferID, owner: invocationContext.clientID, offset: offset, data: data)
  }

  public func serviceCommitFileUpload(
    transferID: String, clientRequestID: String?, invocationContext: MCPInvocationContext,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectWriteReceipt {
    try Self.checkDeadline(deadline)
    let upload = try await fileUploads.startCommit(transferID, owner: invocationContext.clientID)
    if let receipt = upload.receipt { return receipt }
    do {
      try Self.validateTransferContent(upload.content)
      let request = upload.request
      let project = try await approvedDirectProject(
        projectID: request.projectID, kind: .fileWrite,
        summary: "导入文件 \(request.relativePath)（\(request.byteCount) 字节）",
        payload: FileUploadApproval(
          clientID: invocationContext.clientID.rawValue, transferID: transferID, request: request),
        clientRequestID: clientRequestID
      )
      try Self.checkDeadline(deadline)
      guard let mode = ProjectWriteMode(rawValue: request.mode) else {
        throw BridgeMCPQueryError.contractRejected
      }
      let operationID = "op-" + UUID().uuidString.lowercased()
      let result = try await withDirectLease(
        project: project, owner: .directFileOperation(operationID: operationID)
      ) {
        try Self.checkDeadline(deadline)
        return try await self.mutations.writeTransferFile(
          projectID: ProjectID(rawValue: request.projectID), relativePath: request.relativePath,
          content: upload.content, mode: mode, expectedSHA256: request.expectedSHA256,
          createParents: request.createParents, maximumBytes: MCPFileTransferLimits.maximumFileBytes
        )
      }
      let receipt = MCPDirectWriteReceipt(
        operationID: operationID, relativePath: result.relativePath, operation: result.operation,
        oldSHA256: result.oldSHA256, newSHA256: result.newSHA256, byteCount: result.byteCount
      )
      await fileUploads.finishCommit(transferID, receipt: receipt)
      return receipt
    } catch {
      await fileUploads.abandonCommit(transferID)
      if error is ProjectMutationError { throw Self.publicMutationError(error) }
      throw error
    }
  }

  public func serviceCancelFileUpload(
    transferID: String, invocationContext: MCPInvocationContext,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPFileTransfer {
    try Self.checkDeadline(deadline)
    return try await fileUploads.cancel(transferID, owner: invocationContext.clientID)
  }

  public func serviceReadFileChunk(
    _ request: MCPFileChunkRequest, invocationContext: MCPInvocationContext,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPFileChunk {
    try Self.checkDeadline(deadline)
    guard request.offset >= 0,
      (1...MCPFileTransferLimits.maximumChunkBytes).contains(request.length),
      request.offset == 0 || request.expectedSHA256 != nil
    else { throw BridgeMCPQueryError.contractRejected }
    let project = try await readableProject(request.projectID)
    let data: Data
    do {
      data = try await mutations.readTransferFile(
        projectID: project.id, relativePath: request.relativePath,
        maximumBytes: MCPFileTransferLimits.maximumFileBytes)
    } catch { throw Self.publicMutationError(error) }
    try Self.validateTransferContent(data)
    let revision = SecureFileRevision.digest(of: data)
    guard request.expectedSHA256 == nil || request.expectedSHA256 == revision.sha256 else {
      throw BridgeMCPQueryError.fileRevisionConflict
    }
    guard request.offset <= data.count else { throw BridgeMCPQueryError.contractRejected }
    try await authorizeFileExport(
      request: request, sha256: revision.sha256, byteCount: data.count,
      clientID: invocationContext.clientID.rawValue)
    try Self.checkDeadline(deadline)
    let end = min(data.count, request.offset + request.length)
    let chunk = data.subdata(in: request.offset..<end)
    return MCPFileChunk(
      relativePath: request.relativePath, offset: request.offset, byteCount: chunk.count,
      totalBytes: data.count, sha256: revision.sha256, dataBase64: chunk.base64EncodedString(),
      nextOffset: end < data.count ? end : nil
    )
  }

  private func authorizeFileExport(
    request: MCPFileChunkRequest, sha256: String, byteCount: Int, clientID: String
  ) async throws {
    let approval = FileExportApproval(
      clientID: clientID, projectID: request.projectID, relativePath: request.relativePath,
      sha256: sha256, byteCount: byteCount)
    let key = DirectActionApprovalCenter.payloadDigest(approval)
    fileExportGrants = fileExportGrants.filter { $0.value > Date() }
    if fileExportGrants[key] != nil { return }
    let project = try await readableProject(request.projectID)
    try await requireDirectApproval(
      project: project, kind: .fileExport,
      summary: "导出原始文件 \(request.relativePath)（\(byteCount) 字节）", payload: approval,
      clientRequestID: key)
    guard fileExportGrants.count < 128 else { throw BridgeMCPQueryError.busy }
    fileExportGrants[key] = Date().addingTimeInterval(15 * 60)
  }

  private static func validateTransferContent(_ data: Data) throws {
    let text = String(decoding: data, as: UTF8.self)
    guard OutboundContentSecurity.isSafeSecrets(text),
      !ProjectSecretRedactor.containsSensitiveContent(text)
    else {
      throw BridgeMCPQueryError.unsafeContentDetected
    }
  }
}

private struct FileUploadApproval: Encodable {
  let clientID: String
  let transferID: String
  let request: MCPFileUploadRequest
}

private struct FileExportApproval: Encodable {
  let clientID: String
  let projectID: String
  let relativePath: String
  let sha256: String
  let byteCount: Int
}
