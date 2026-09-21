import BridgeFiles
import BridgeSecurity
import Foundation
import MCP

extension MCPServiceToolDispatcher {
  private func parseDirectMutation(
    _ arguments: [String: Value]?
  ) throws -> MCPDirectMutationRequest {
    guard try JSONEncoder().encode(Value.object(arguments ?? [:])).count <= 512 * 1_024 else {
      throw MCPError.invalidParams("The mutation request is too large.")
    }
    let values = try StrictToolArguments(
      arguments,
      allowed: [
        "project_id", "kind", "relative_path", "mode", "content", "expected_sha256",
        "create_parents", "old_text", "new_text", "expected_replacements", "patch",
        "client_request_id",
      ],
      required: ["project_id", "kind"]
    )
    let kind = try values.requiredIdentifier("kind", maximumUTF8Bytes: 16)
    guard ["write", "edit", "patch"].contains(kind) else {
      throw MCPError.invalidParams("Argument 'kind' must be write, edit, or patch.")
    }
    let relativePath = try values.optionalIdentifier("relative_path", maximumUTF8Bytes: 1_024)
    if let relativePath, !OutboundContentSecurity.isSafeRelativePath(relativePath) {
      throw MCPError.invalidParams("Argument 'relative_path' must be a safe relative path.")
    }
    let content = try values.optionalText("content", maximumUTF8Bytes: 256 * 1_024)
    let oldText = try values.optionalText("old_text", maximumUTF8Bytes: 256 * 1_024)
    let newText = try values.optionalText("new_text", maximumUTF8Bytes: 256 * 1_024)
    let patch = try values.optionalText("patch", maximumUTF8Bytes: 256 * 1_024)
    guard
      [content, newText, patch].compactMap({ $0 }).allSatisfy(OutboundContentSecurity.isSafeSecrets)
    else {
      throw BridgeMCPQueryError.unsafeContentDetected
    }
    return MCPDirectMutationRequest(
      projectID: try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128),
      kind: kind,
      relativePath: relativePath,
      mode: try values.optionalIdentifier("mode", maximumUTF8Bytes: 16),
      content: content,
      expectedSHA256: try values.optionalIdentifier("expected_sha256", maximumUTF8Bytes: 64),
      createParents: try values.optionalBoolean("create_parents") ?? false,
      oldText: oldText,
      newText: newText,
      expectedReplacements: try values.optionalPositiveInteger(
        "expected_replacements", maximum: 1_000),
      patch: patch,
      clientRequestID: try values.optionalIdentifier("client_request_id", maximumUTF8Bytes: 512)
    )
  }

  private func parseDirectMutationOperation(
    _ arguments: [String: Value]?
  ) throws -> (operationID: String, clientRequestID: String?) {
    let values = try StrictToolArguments(
      arguments,
      allowed: ["operation_id", "client_request_id"],
      required: ["operation_id"]
    )
    return (
      try values.requiredIdentifier("operation_id", maximumUTF8Bytes: 128),
      try values.optionalIdentifier("client_request_id", maximumUTF8Bytes: 512)
    )
  }

  func callDirectPreviewProjectMutation(_ arguments: [String: Value]?) async throws
    -> CallTool.Result
  {
    let request = try parseDirectMutation(arguments)
    let deadline = clock.now.advanced(by: deadlines.mutation)
    let preview = try await withToolDeadline(until: deadline) {
      try await service.serviceDirectPreviewMutation(request, deadline: deadline)
    }
    return try resultEncoder.encode(ServiceDirectMutationPreviewOutput(preview: preview))
  }

  func callDirectApplyProjectMutation(_ arguments: [String: Value]?) async throws -> CallTool.Result
  {
    let parsed = try parseDirectMutationOperation(arguments)
    let deadline = clock.now.advanced(by: deadlines.mutation)
    let receipt = try await withToolDeadline(until: deadline) {
      try await service.serviceDirectApplyMutation(
        MCPDirectApplyMutationRequest(
          operationID: parsed.operationID,
          clientRequestID: parsed.clientRequestID
        ),
        deadline: deadline
      )
    }
    return try resultEncoder.encode(ServiceDirectMutationReceiptOutput(receipt: receipt))
  }

  func callDirectUndoProjectMutation(_ arguments: [String: Value]?) async throws -> CallTool.Result
  {
    let parsed = try parseDirectMutationOperation(arguments)
    let deadline = clock.now.advanced(by: deadlines.mutation)
    let receipt = try await withToolDeadline(until: deadline) {
      try await service.serviceDirectUndoMutation(
        MCPDirectUndoMutationRequest(
          operationID: parsed.operationID,
          clientRequestID: parsed.clientRequestID
        ),
        deadline: deadline
      )
    }
    return try resultEncoder.encode(ServiceDirectMutationReceiptOutput(receipt: receipt))
  }
}

struct ServiceDirectMutationPreviewOutput: Codable, Sendable {
  let schemaVersion = 1
  let receiptType = "file_mutation_preview"
  let operationID: String
  let projectID: String
  let kind: String
  let changedFiles: [MCPDirectMutationFile]
  let preparedAt: String

  init(preview: MCPDirectMutationPreview) {
    operationID = preview.operationID
    projectID = preview.projectID
    kind = preview.kind
    changedFiles = preview.changedFiles
    preparedAt = preview.preparedAt
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case receiptType = "receipt_type"
    case operationID = "operation_id"
    case projectID = "project_id"
    case kind
    case changedFiles = "changed_files"
    case preparedAt = "prepared_at"
  }
}

struct ServiceDirectMutationReceiptOutput: Codable, Sendable {
  let schemaVersion = 1
  let receiptType = "file_mutation"
  let operationID: String
  let projectID: String
  let kind: String
  let status: String
  let changedFiles: [MCPDirectMutationFile]
  let timestamp: String

  init(receipt: MCPDirectMutationReceipt) {
    operationID = receipt.operationID
    projectID = receipt.projectID
    kind = receipt.kind
    status = receipt.status
    changedFiles = receipt.changedFiles
    timestamp = receipt.timestamp
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case receiptType = "receipt_type"
    case operationID = "operation_id"
    case projectID = "project_id"
    case kind
    case status
    case changedFiles = "changed_files"
    case timestamp
  }
}
