import BridgeSecurity
import Foundation
import MCP

extension MCPServiceToolDispatcher {
  func callFileTransfer(
    _ name: MCPServiceToolName,
    arguments: [String: Value]?,
    sessionID: String
  ) async throws -> CallTool.Result {
    let context = MCPInvocationContext(clientID: clientID, sessionID: sessionID)
    let deadline = clock.now.advanced(by: deadlines.mutation)
    switch name {
    case .openFileTransfer:
      return try await openFileTransfer(arguments)
    case .importChatFile:
      return try await importChatFile(arguments, context: context)
    case .beginFileUpload:
      let request = try parseFileUpload(arguments)
      let transfer = try await withToolDeadline(until: deadline) {
        try await service.serviceBeginFileUpload(
          request, invocationContext: context, deadline: deadline)
      }
      return try resultEncoder.encode(transfer)
    case .appendFileUpload:
      return try await appendFileUpload(arguments, context: context, deadline: deadline)
    case .commitFileUpload:
      let values = try StrictToolArguments(
        arguments, allowed: ["transfer_id", "client_request_id"], required: ["transfer_id"])
      let transferID = try values.requiredIdentifier("transfer_id", maximumUTF8Bytes: 128)
      let requestID = try values.optionalIdentifier("client_request_id", maximumUTF8Bytes: 512)
      let receipt = try await withToolDeadline(until: deadline) {
        try await service.serviceCommitFileUpload(
          transferID: transferID, clientRequestID: requestID,
          invocationContext: context, deadline: deadline)
      }
      return try resultEncoder.encode(ServiceDirectMutationOutput(receipt: receipt))
    case .cancelFileUpload:
      let values = try StrictToolArguments(
        arguments, allowed: ["transfer_id"], required: ["transfer_id"])
      let transferID = try values.requiredIdentifier("transfer_id", maximumUTF8Bytes: 128)
      let transfer = try await withToolDeadline(until: deadline) {
        try await service.serviceCancelFileUpload(
          transferID: transferID, invocationContext: context, deadline: deadline)
      }
      return try resultEncoder.encode(transfer)
    case .readFileChunk:
      let request = try parseFileChunk(arguments)
      let chunk = try await withToolDeadline(until: deadline) {
        try await service.serviceReadFileChunk(
          request, invocationContext: context, deadline: deadline)
      }
      return try resultEncoder.encode(chunk)
    default:
      throw MCPError.invalidParams("Unknown file transfer tool.")
    }
  }

  private func appendFileUpload(
    _ arguments: [String: Value]?, context: MCPInvocationContext,
    deadline: ContinuousClock.Instant
  ) async throws -> CallTool.Result {
    let values = try StrictToolArguments(
      arguments, allowed: ["transfer_id", "offset", "data_base64"],
      required: ["transfer_id", "offset", "data_base64"])
    let transferID = try values.requiredIdentifier("transfer_id", maximumUTF8Bytes: 128)
    let offset =
      try values.optionalNonnegativeInteger(
        "offset", maximum: Int64(MCPFileTransferLimits.maximumFileBytes)) ?? 0
    let encoded = try values.requiredIdentifier(
      "data_base64", maximumUTF8Bytes: MCPFileTransferLimits.maximumBase64Bytes)
    guard let data = Data(base64Encoded: encoded), !data.isEmpty,
      data.count <= MCPFileTransferLimits.maximumChunkBytes
    else { throw MCPError.invalidParams("data_base64 must encode 1 to 49152 bytes.") }
    let transfer = try await withToolDeadline(until: deadline) {
      try await service.serviceAppendFileUpload(
        transferID: transferID, offset: Int(offset), dataBase64: encoded,
        invocationContext: context, deadline: deadline)
    }
    return try resultEncoder.encode(transfer)
  }

  private func parseFileUpload(_ arguments: [String: Value]?) throws -> MCPFileUploadRequest {
    let values = try StrictToolArguments(
      arguments,
      allowed: [
        "project_id", "relative_path", "byte_count", "sha256", "mode", "expected_sha256",
        "create_parents",
      ], required: ["project_id", "relative_path", "byte_count", "sha256", "mode"])
    guard let digest = try transferDigest(values, key: "sha256") else {
      throw MCPError.invalidParams("sha256 is required.")
    }
    let mode = try values.requiredIdentifier("mode", maximumUTF8Bytes: 16)
    let expected = try transferDigest(values, key: "expected_sha256")
    guard mode == "create" || mode == "replace", mode != "replace" || expected != nil else {
      throw MCPError.invalidParams("Use create, or replace with expected_sha256.")
    }
    let count =
      try values.optionalNonnegativeInteger(
        "byte_count", maximum: Int64(MCPFileTransferLimits.maximumFileBytes)) ?? 0
    return try MCPFileUploadRequest(
      projectID: values.requiredIdentifier("project_id", maximumUTF8Bytes: 128),
      relativePath: transferPath(values), byteCount: Int(count),
      sha256: digest, mode: mode,
      expectedSHA256: expected, createParents: values.optionalBoolean("create_parents") ?? false)
  }

  private func parseFileChunk(_ arguments: [String: Value]?) throws -> MCPFileChunkRequest {
    let values = try StrictToolArguments(
      arguments,
      allowed: ["project_id", "relative_path", "offset", "length", "expected_sha256"],
      required: ["project_id", "relative_path"])
    let offset =
      try values.optionalNonnegativeInteger(
        "offset", maximum: Int64(MCPFileTransferLimits.maximumFileBytes)) ?? 0
    let expected = try transferDigest(values, key: "expected_sha256")
    guard offset == 0 || expected != nil else {
      throw MCPError.invalidParams(
        "Subsequent chunks require expected_sha256 from the first chunk.")
    }
    return try MCPFileChunkRequest(
      projectID: values.requiredIdentifier("project_id", maximumUTF8Bytes: 128),
      relativePath: transferPath(values), offset: Int(offset),
      length: values.optionalPositiveInteger(
        "length", maximum: MCPFileTransferLimits.maximumChunkBytes)
        ?? MCPFileTransferLimits.maximumChunkBytes,
      expectedSHA256: expected)
  }

  func transferPath(_ values: StrictToolArguments) throws -> String {
    let path = try values.requiredIdentifier("relative_path", maximumUTF8Bytes: 1_024)
    guard OutboundContentSecurity.isSafeRelativePath(path) else {
      throw MCPError.invalidParams("relative_path must be a safe project-relative path.")
    }
    return path
  }

  func transferDigest(_ values: StrictToolArguments, key: String) throws -> String? {
    guard let value = try values.optionalIdentifier(key, maximumUTF8Bytes: 64) else { return nil }
    guard value.utf8.count == 64,
      value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw MCPError.invalidParams("\(key) must be a lowercase SHA-256 digest.") }
    return value
  }
}
