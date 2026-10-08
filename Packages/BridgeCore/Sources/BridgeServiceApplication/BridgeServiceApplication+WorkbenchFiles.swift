import BridgeFiles
import BridgeMCP
import BridgeSecurity
import Foundation

extension BridgeServiceApplication {
  public func serviceWorkbenchListDirectory(
    projectID: String, relativeDirectory: String?, cursor: String?, limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectDirectoryPage {
    try await serviceListProjectDirectory(
      projectID: projectID, relativeDirectory: relativeDirectory, depth: 0,
      kind: "all", cursor: cursor, limit: limit, deadline: deadline)
  }

  public func serviceWorkbenchReadFile(
    projectID: String, relativePath: String, startLine: Int, lineCount: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectFileReadPage {
    try Self.checkDeadline(deadline)
    do {
      let page = try await readProjectFilePage(
        projectID: projectID, relativePath: relativePath, startLine: startLine,
        lineCount: lineCount)
      guard page.startLine == 1, !page.truncated, page.redactedLineCount == 0 else { return page }
      let project = try await readableProject(projectID)
      let original = try SecureFileReader(maximumBytes: 256 * 1_024, maximumLines: 10_001).read(
        SecureRelativePath(relativePath), through: WorkbenchProjectAccess.resolver(for: project))
      guard original.sha256 == page.sha256, !original.truncated else {
        throw BridgeMCPQueryError.fileRevisionConflict
      }
      return MCPProjectFileReadPage(
        relativePath: page.relativePath, startLine: page.startLine, endLine: page.endLine,
        content: original.text, redactedLineCount: 0, truncated: false, nextStartLine: nil,
        sha256: original.sha256, byteCount: original.byteCount)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as BridgeMCPQueryError {
      throw error
    } catch PathSecurityError.binaryFileBlocked {
      throw WorkbenchFileReadError.binaryFile
    } catch PathSecurityError.fileTooLarge(let maximumBytes) {
      throw WorkbenchFileReadError.fileTooLarge(maximumBytes: maximumBytes)
    } catch {
      throw Self.publicFileError(error)
    }
  }

  public func serviceWorkbenchPreviewWrite(
    projectID: String, relativePath: String, content: String, expectedSHA256: String,
    clientRequestID: String, deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectMutationPreview {
    let page = try await serviceWorkbenchReadFile(
      projectID: projectID, relativePath: relativePath, startLine: 1, lineCount: 10_000,
      deadline: deadline)
    guard !page.truncated, page.redactedLineCount == 0, page.nextStartLine == nil,
      content.utf8.count <= 256 * 1_024
    else { throw BridgeMCPQueryError.contractRejected }
    guard page.sha256 == expectedSHA256 else { throw BridgeMCPQueryError.fileRevisionConflict }
    return try await serviceDirectPreviewMutation(
      MCPDirectMutationRequest(
        projectID: projectID, kind: "write", relativePath: relativePath, mode: "replace",
        content: content, expectedSHA256: expectedSHA256, clientRequestID: clientRequestID),
      deadline: deadline)
  }

  public func serviceWorkbenchApplyWrite(
    projectID: String, relativePath: String, operationID: String, clientRequestID: String,
    confirmed: Bool, deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectMutationReceipt {
    try Self.checkDeadline(deadline)
    _ = try await writableProject(projectID)
    guard confirmed,
      let operation = await directMutationOperations.operation(operationID),
      operation.request.projectID == projectID,
      operation.request.relativePath == relativePath,
      operation.request.kind == "write", operation.request.mode == "replace"
    else { throw BridgeMCPQueryError.contractRejected }
    if case .applied = operation.state {
      guard operation.appliedClientRequestID == clientRequestID else {
        throw BridgeMCPQueryError.contractRejected
      }
      return Self.mutationReceipt(operation, status: "applied")
    }
    return try await serviceDirectApplyMutation(
      MCPDirectApplyMutationRequest(operationID: operationID, clientRequestID: clientRequestID),
      deadline: deadline)
  }
}
