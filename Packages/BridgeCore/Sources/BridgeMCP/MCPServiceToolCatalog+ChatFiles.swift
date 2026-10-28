import MCP

extension MCPServiceToolCatalog {
  static let openFileTransfer = Tool(
    name: MCPServiceToolName.openFileTransfer.rawValue,
    title: "项目文件传输",
    description:
      "Open the in-chat file transfer UI for a registered project. Use direction=download and the "
      + "result's relative_path when the user asks to receive a generated file. The UI assembles "
      + "and verifies the file and offers a download button. Use direction=upload to let the user "
      + "choose a local file. For an existing ChatGPT chat attachment, use import_chat_file directly.",
    inputSchema: objectSchema(
      properties: [
        "project_id": opaqueProjectIDSchema,
        "direction": ["type": "string", "enum": ["upload", "download"]],
        "relative_path": nullableStringSchema(maximum: 1_024),
      ], required: ["project_id", "direction"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false),
    outputSchema: objectSchema(
      properties: [
        "project_id": stringSchema, "project_name": stringSchema,
        "direction": stringSchema, "relative_path": stringSchema,
        "maximum_file_bytes": integerSchema(minimum: 1), "chunk_bytes": integerSchema(minimum: 1),
      ], required: ["project_id", "project_name", "direction", "maximum_file_bytes", "chunk_bytes"]
    ),
    _meta: Metadata(additionalFields: [
      "ui": ["resourceUri": .string(MCPFileTransferResource.uri)],
      "openai/outputTemplate": .string(MCPFileTransferResource.uri),
      "openai/widgetAccessible": true,
      "openai/toolInvocation/invoking": "正在打开文件传输",
      "openai/toolInvocation/invoked": "文件传输已就绪",
    ])
  )

  static let importChatFile = Tool(
    name: MCPServiceToolName.importChatFile.rawValue,
    title: "导入聊天附件",
    description:
      "Import a user-provided ChatGPT attachment into a registered project. Pass the host-provided "
      + "file reference; Bridge downloads the real bytes, verifies the file and applies local write "
      + "approval. Maximum 16 MiB. Retrying the same file_id and target reuses the transfer and "
      + "receipt. Replace requires the existing file's expected_sha256. If approval is required, "
      + "ask the user to approve in Bridge, then retry the same request.",
    inputSchema: objectSchema(
      properties: [
        "project_id": opaqueProjectIDSchema,
        "relative_path": boundedStringSchema(maximum: 1_024),
        "file": objectSchema(
          properties: [
            "download_url": boundedStringSchema(maximum: 16_384),
            "file_id": boundedStringSchema(maximum: 512),
            "mime_type": boundedStringSchema(maximum: 256),
            "file_name": boundedStringSchema(maximum: 1_024),
          ], required: ["download_url", "file_id"]
        ),
        "mode": ["type": "string", "enum": ["create", "replace"]],
        "expected_sha256": nullableStringSchema(maximum: 64),
        "create_parents": boolSchema,
        "client_request_id": nullableStringSchema(maximum: 512),
      ], required: ["project_id", "relative_path", "file", "mode"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false),
    outputSchema: directMutationOutputSchema,
    _meta: Metadata(additionalFields: ["openai/fileParams": ["file"]])
  )
}
