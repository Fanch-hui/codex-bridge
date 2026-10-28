import Foundation
import MCP

extension MCPServiceToolDispatcher {
  func openFileTransfer(_ arguments: [String: Value]?) async throws -> CallTool.Result {
    let values = try StrictToolArguments(
      arguments, allowed: ["project_id", "direction", "relative_path"],
      required: ["project_id", "direction"])
    let projectID = try values.requiredIdentifier("project_id", maximumUTF8Bytes: 128)
    let direction = try values.requiredIdentifier("direction", maximumUTF8Bytes: 16)
    guard direction == "upload" || direction == "download" else {
      throw MCPError.invalidParams("direction must be upload or download.")
    }
    let relativePath = try values.optionalIdentifier("relative_path", maximumUTF8Bytes: 1_024)
    if relativePath != nil { _ = try transferPath(values) }
    guard direction != "download" || relativePath != nil else {
      throw MCPError.invalidParams("A download requires relative_path.")
    }
    let deadline = clock.now.advanced(by: deadlines.read)
    let project = try await withToolDeadline(until: deadline) {
      try await service.serviceProject(projectID: projectID, deadline: deadline)
    }
    return try resultEncoder.encode(
      MCPFileTransferView(
        projectID: projectID, projectName: project.name, relativePath: relativePath,
        direction: direction, maximumFileBytes: MCPFileTransferLimits.maximumFileBytes,
        chunkBytes: MCPFileTransferLimits.maximumChunkBytes))
  }

  func importChatFile(_ arguments: [String: Value]?, context: MCPInvocationContext) async throws
    -> CallTool.Result
  {
    let request = try parseChatFileImport(arguments)
    let deadline = clock.now.advanced(by: .seconds(60))
    do {
      let receipt = try await withToolDeadline(until: deadline) {
        try await service.serviceImportChatFile(
          request, invocationContext: context, deadline: deadline)
      }
      return try resultEncoder.encode(ServiceDirectMutationOutput(receipt: receipt))
    } catch let error as MCPChatFileImportError {
      return try chatFileImportError(error)
    }
  }

  private func parseChatFileImport(_ arguments: [String: Value]?) throws -> MCPChatFileImportRequest
  {
    let values = try StrictToolArguments(
      arguments,
      allowed: [
        "project_id", "relative_path", "file", "mode", "expected_sha256", "create_parents",
        "client_request_id",
      ], required: ["project_id", "relative_path", "file", "mode"])
    guard let fileObject = arguments?["file"]?.objectValue else {
      throw MCPError.invalidParams("file must be a host-provided attachment reference.")
    }
    let file = try StrictToolArguments(
      fileObject, allowed: ["download_url", "file_id", "mime_type", "file_name"],
      required: ["download_url", "file_id"])
    let mode = try values.requiredIdentifier("mode", maximumUTF8Bytes: 16)
    let expected = try transferDigest(values, key: "expected_sha256")
    guard mode == "create" || mode == "replace", mode != "replace" || expected != nil else {
      throw MCPError.invalidParams("Use create, or replace with expected_sha256.")
    }
    return try MCPChatFileImportRequest(
      projectID: values.requiredIdentifier("project_id", maximumUTF8Bytes: 128),
      relativePath: transferPath(values),
      file: MCPChatFileReference(
        downloadURL: file.requiredIdentifier("download_url", maximumUTF8Bytes: 16_384),
        fileID: file.requiredIdentifier("file_id", maximumUTF8Bytes: 512),
        mimeType: file.optionalIdentifier("mime_type", maximumUTF8Bytes: 256),
        fileName: file.optionalIdentifier("file_name", maximumUTF8Bytes: 1_024)),
      mode: mode, expectedSHA256: expected,
      createParents: values.optionalBoolean("create_parents") ?? false,
      clientRequestID: values.optionalIdentifier("client_request_id", maximumUTF8Bytes: 512))
  }

  private func chatFileImportError(_ error: MCPChatFileImportError) throws -> CallTool.Result {
    let detail: (String, MCPToolErrorCategory, String, Bool, String)
    switch error {
    case .unsupportedSource:
      detail = (
        "attachment_source_unsupported", .callerError,
        "Use a ChatGPT-provided attachment reference, or open_file_transfer to choose a local file.",
        false, "open_file_transfer"
      )
    case .expiredSource:
      detail = (
        "attachment_url_expired", .callerError,
        "The attachment download has expired. Attach the file again to obtain a fresh reference.",
        false, "refresh_attachment_reference"
      )
    case .downloadFailed:
      detail = (
        "attachment_download_failed", .infrastructureFailure,
        "The attachment could not be downloaded. Check the connection and retry the same request.",
        true, "retry_same_request"
      )
    case .fileTooLarge:
      detail = (
        "attachment_too_large", .callerError, "The attachment exceeds the 16 MiB file limit.",
        false, "choose_smaller_file"
      )
    }
    return try resultEncoder.encode(
      MCPToolErrorOutput(
        error: MCPToolErrorDTO(
          code: detail.0, category: detail.1, message: detail.2, retryable: detail.3,
          nextAction: detail.4)), isError: true)
  }
}
