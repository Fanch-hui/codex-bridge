import BridgeDomain
import BridgeFiles
import BridgeMCP
import BridgeSecurity
import Foundation

extension BridgeServiceApplication {
  public func serviceDirectPreviewMutation(
    _ request: MCPDirectMutationRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectMutationPreview {
    try Self.checkDeadline(deadline)
    _ = try await writableProject(request.projectID)
    let prepared = try await prepareDirectMutation(request)
    let operationID = "op-" + UUID().uuidString.lowercased()
    await directMutationOperations.insertPending(
      operationID: operationID,
      request: request,
      prepared: prepared
    )
    return MCPDirectMutationPreview(
      operationID: operationID,
      projectID: prepared.projectID.rawValue,
      kind: prepared.kind.rawValue,
      changedFiles: Self.mutationFiles(prepared.changedFiles),
      preparedAt: Self.mutationTimestamp(prepared.preparedAt)
    )
  }

  public func serviceDirectApplyMutation(
    _ request: MCPDirectApplyMutationRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectMutationReceipt {
    try Self.checkDeadline(deadline)
    guard let operation = await directMutationOperations.operation(request.operationID) else {
      throw BridgeMCPQueryError.contractRejected
    }
    guard case .pending = operation.state else { throw BridgeMCPQueryError.contractRejected }
    let project = try await approvedDirectProject(
      projectID: operation.request.projectID,
      kind: .fileWrite,
      summary: "Apply (operation.request.kind) mutation (request.operationID)",
      payload: operation.request,
      clientRequestID: request.clientRequestID ?? operation.request.clientRequestID
    )
    do {
      _ = try await withDirectLease(
        project: project,
        owner: .directFileOperation(operationID: request.operationID)
      ) {
        try await self.mutations.apply(operation.prepared)
      }
      guard let applied = await directMutationOperations.markApplied(request.operationID) else {
        throw BridgeMCPQueryError.contractRejected
      }
      return Self.mutationReceipt(applied, status: "applied")
    } catch {
      throw Self.publicMutationError(error)
    }
  }

  public func serviceDirectUndoMutation(
    _ request: MCPDirectUndoMutationRequest,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPDirectMutationReceipt {
    try Self.checkDeadline(deadline)
    guard let operation = await directMutationOperations.operation(request.operationID) else {
      throw BridgeMCPQueryError.contractRejected
    }
    guard case .applied = operation.state else { throw BridgeMCPQueryError.contractRejected }
    let project = try await approvedDirectProject(
      projectID: operation.request.projectID,
      kind: .fileWrite,
      summary: "Undo file mutation (request.operationID)",
      payload: request,
      clientRequestID: request.clientRequestID
    )
    do {
      _ = try await withDirectLease(
        project: project,
        owner: .directFileOperation(operationID: "undo-(request.operationID)")
      ) {
        try await self.mutations.undo(operation.prepared)
      }
      guard let undone = await directMutationOperations.markUndone(request.operationID) else {
        throw BridgeMCPQueryError.contractRejected
      }
      return Self.mutationReceipt(undone, status: "undone")
    } catch {
      throw Self.publicMutationError(error)
    }
  }

  func prepareDirectMutation(
    _ request: MCPDirectMutationRequest
  ) async throws -> PreparedProjectMutation {
    guard !request.projectID.isEmpty, request.projectID.utf8.count <= 128 else {
      throw BridgeMCPQueryError.projectNotFound
    }
    switch request.kind {
    case ProjectMutationKind.write.rawValue:
      guard
        let path = request.relativePath,
        let mode = request.mode.flatMap(ProjectWriteMode.init(rawValue:)),
        let content = request.content
      else { throw BridgeMCPQueryError.contractRejected }
      return try await mutations.prepare(
        .write(
          ProjectWriteRequest(
            projectID: ProjectID(rawValue: request.projectID),
            relativePath: path,
            mode: mode,
            content: content,
            expectedSHA256: request.expectedSHA256,
            createParents: request.createParents
          )
        )
      )
    case ProjectMutationKind.edit.rawValue:
      guard
        let path = request.relativePath,
        let expectedSHA256 = request.expectedSHA256,
        let oldText = request.oldText,
        let newText = request.newText
      else { throw BridgeMCPQueryError.contractRejected }
      return try await mutations.prepare(
        .edit(
          ProjectEditRequest(
            projectID: ProjectID(rawValue: request.projectID),
            relativePath: path,
            expectedSHA256: expectedSHA256,
            oldText: oldText,
            newText: newText,
            expectedReplacements: request.expectedReplacements ?? 1
          )
        )
      )
    case ProjectMutationKind.patch.rawValue:
      guard let patch = request.patch, !patch.isEmpty else {
        throw BridgeMCPQueryError.contractRejected
      }
      let operations: [ProjectPatchFileOperation]
      do {
        operations = try ProjectPatchParser.parse(patch)
      } catch ProjectPatchParserError.absolutePath {
        throw BridgeMCPQueryError.pathForbidden
      } catch {
        throw BridgeMCPQueryError.invalidPatchSyntax
      }
      return try await mutations.prepare(
        .patch(
          ProjectApplyPatchRequest(
            projectID: ProjectID(rawValue: request.projectID),
            operations: operations
          )
        )
      )
    default:
      throw BridgeMCPQueryError.contractRejected
    }
  }

  private static func mutationFiles(
    _ changes: [PreparedProjectMutationFile]
  ) -> [MCPDirectMutationFile] {
    changes.map { change in
      MCPDirectMutationFile(
        relativePath: change.relativePath,
        beforeRevision: revision(change.beforeRevision),
        afterRevision: revision(change.afterRevision),
        boundedDiff: safeMutationDiff(change.boundedDiff)
      )
    }
  }

  private static func mutationReceipt(
    _ operation: StoredDirectMutation,
    status: String
  ) -> MCPDirectMutationReceipt {
    MCPDirectMutationReceipt(
      operationID: operation.operationID,
      projectID: operation.prepared.projectID.rawValue,
      kind: operation.prepared.kind.rawValue,
      status: status,
      changedFiles: mutationFiles(operation.prepared.changedFiles),
      timestamp: mutationTimestamp(operation.createdAt)
    )
  }

  private static func revision(_ value: FileRevision?) -> MCPDirectMutationRevision? {
    value.map { MCPDirectMutationRevision(sha256: $0.sha256, byteCount: $0.byteCount) }
  }

  private static func revision(_ value: FileRevision) -> MCPDirectMutationRevision {
    MCPDirectMutationRevision(sha256: value.sha256, byteCount: value.byteCount)
  }

  private static func safeMutationDiff(_ diff: BoundedDiff) -> MCPBoundedDiff {
    MCPBoundedDiff(
      removedLines: diff.removedLines.map {
        OutboundContentSecurity.redacted($0, maximumUTF8Bytes: 64 * 1_024)
      },
      addedLines: diff.addedLines.map {
        OutboundContentSecurity.redacted($0, maximumUTF8Bytes: 64 * 1_024)
      },
      truncated: diff.truncated,
      byteCount: diff.byteCount
    )
  }

  private static func mutationTimestamp(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
  }
}
