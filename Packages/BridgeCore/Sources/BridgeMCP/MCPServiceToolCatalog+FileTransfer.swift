import MCP

extension MCPServiceToolCatalog {
  private static let fileTransferSchema = objectSchema(
    properties: [
      "transfer_id": stringSchema,
      "status": stringSchema,
      "received_bytes": integerSchema(minimum: 0),
      "total_bytes": integerSchema(minimum: 0),
      "expires_at": stringSchema,
    ],
    required: ["transfer_id", "status", "received_bytes", "total_bytes", "expires_at"]
  )

  static let beginFileUpload = Tool(
    name: MCPServiceToolName.beginFileUpload.rawValue,
    title: "Begin project file upload",
    description:
      "Stage an explicitly requested file import into a registered project. Supply the real file's "
      + "byte count and SHA-256; never invent attachment bytes. Maximum file size is 16 MiB. "
      + "Send base64 chunks with append_file_upload, then commit_file_upload to request the normal "
      + "local write approval. Staging expires after 15 minutes. No project file is written until commit.",
    inputSchema: objectSchema(
      properties: [
        "project_id": opaqueProjectIDSchema,
        "relative_path": boundedStringSchema(maximum: 1_024),
        "byte_count": integerSchema(minimum: 0, maximum: MCPFileTransferLimits.maximumFileBytes),
        "sha256": boundedStringSchema(maximum: 64),
        "mode": ["type": "string", "enum": ["create", "replace"]],
        "expected_sha256": nullableStringSchema(maximum: 64),
        "create_parents": boolSchema,
      ],
      required: ["project_id", "relative_path", "byte_count", "sha256", "mode"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false),
    outputSchema: fileTransferSchema
  )

  static let appendFileUpload = Tool(
    name: MCPServiceToolName.appendFileUpload.rawValue,
    title: "Append project file upload",
    description:
      "Append up to 48 KiB of real file bytes encoded as base64 at the reported received_bytes offset. "
      + "An identical chunk at the same offset may be retried after a lost response. "
      + "Use cancel_file_upload to release staging when the import is abandoned.",
    inputSchema: objectSchema(
      properties: [
        "transfer_id": boundedStringSchema(maximum: 128),
        "offset": integerSchema(minimum: 0, maximum: MCPFileTransferLimits.maximumFileBytes),
        "data_base64": boundedStringSchema(maximum: MCPFileTransferLimits.maximumBase64Bytes),
      ], required: ["transfer_id", "offset", "data_base64"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false),
    outputSchema: fileTransferSchema
  )

  static let commitFileUpload = Tool(
    name: MCPServiceToolName.commitFileUpload.rawValue,
    title: "Commit project file upload",
    description:
      "Verify the complete upload's length and SHA-256, then write it using project path checks, "
      + "local approval and workspace exclusion. If approval is required, wait for the local user "
      + "and retry this same transfer. A completed transfer returns its original receipt.",
    inputSchema: objectSchema(
      properties: [
        "transfer_id": boundedStringSchema(maximum: 128),
        "client_request_id": nullableStringSchema(maximum: 512),
      ], required: ["transfer_id"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false),
    outputSchema: directMutationOutputSchema
  )

  static let cancelFileUpload = Tool(
    name: MCPServiceToolName.cancelFileUpload.rawValue,
    title: "Cancel project file upload",
    description:
      "Release an unfinished upload's staged bytes. A committed project file is retained.",
    inputSchema: objectSchema(
      properties: ["transfer_id": boundedStringSchema(maximum: 128)], required: ["transfer_id"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false),
    outputSchema: fileTransferSchema
  )

  static let readFileChunk = Tool(
    name: MCPServiceToolName.readFileChunk.rawValue,
    title: "Export project file bytes",
    description:
      "Export an explicitly requested project file as original base64 bytes through local export "
      + "approval and project path checks. Maximum file size is 16 MiB; each chunk is at most 48 KiB. "
      + "Start at offset 0, then pass the returned sha256 as expected_sha256 on every subsequent "
      + "chunk to reject changes during transfer. Use read_project_file for ordinary redacted text "
      + "inspection. The caller must decode and assemble bytes to create a downloadable attachment.",
    inputSchema: objectSchema(
      properties: [
        "project_id": opaqueProjectIDSchema,
        "relative_path": boundedStringSchema(maximum: 1_024),
        "offset": integerSchema(minimum: 0, maximum: MCPFileTransferLimits.maximumFileBytes),
        "length": integerSchema(minimum: 1, maximum: MCPFileTransferLimits.maximumChunkBytes),
        "expected_sha256": nullableStringSchema(maximum: 64),
      ], required: ["project_id", "relative_path"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false),
    outputSchema: objectSchema(
      properties: [
        "relative_path": stringSchema,
        "offset": integerSchema(minimum: 0),
        "byte_count": integerSchema(minimum: 0),
        "total_bytes": integerSchema(minimum: 0),
        "sha256": stringSchema,
        "data_base64": boundedStringSchema(maximum: MCPFileTransferLimits.maximumBase64Bytes),
        "next_offset": integerSchema(minimum: 0),
      ],
      required: ["relative_path", "offset", "byte_count", "total_bytes", "sha256", "data_base64"]
    )
  )
}
