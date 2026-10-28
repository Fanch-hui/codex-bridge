import Foundation

extension BridgeMCPServiceAPI {
  public func serviceImportChatFile(
    _ request: MCPChatFileImportRequest,
    invocationContext: MCPInvocationContext,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectWriteReceipt {
    throw BridgeMCPQueryError.unavailable
  }

  public func serviceBeginFileUpload(
    _ request: MCPFileUploadRequest,
    invocationContext: MCPInvocationContext,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPFileTransfer {
    throw BridgeMCPQueryError.unavailable
  }

  public func serviceAppendFileUpload(
    transferID: String, offset: Int, dataBase64: String,
    invocationContext: MCPInvocationContext,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPFileTransfer {
    throw BridgeMCPQueryError.unavailable
  }

  public func serviceCommitFileUpload(
    transferID: String, clientRequestID: String?,
    invocationContext: MCPInvocationContext,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectWriteReceipt {
    throw BridgeMCPQueryError.unavailable
  }

  public func serviceCancelFileUpload(
    transferID: String,
    invocationContext: MCPInvocationContext,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPFileTransfer {
    throw BridgeMCPQueryError.unavailable
  }

  public func serviceReadFileChunk(
    _ request: MCPFileChunkRequest,
    invocationContext: MCPInvocationContext,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPFileChunk {
    throw BridgeMCPQueryError.unavailable
  }

}
