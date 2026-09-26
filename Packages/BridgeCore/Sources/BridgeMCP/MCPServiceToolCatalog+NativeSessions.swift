import MCP

extension MCPServiceToolCatalog {
  private static var nativeSessionSummaryProperties: [String: Value] {
    [
      "session_id": stringSchema,
      "title": stringSchema,
      "first_prompt": nullableStringSchema(maximum: 8_192),
      "created_at": nullableStringSchema(maximum: 64),
      "updated_at": nullableStringSchema(maximum: 64),
      "message_count": nullableIntegerSchema(minimum: 0),
      "is_indexed": boolSchema,
    ]
  }

  static var nativeSessionSummarySchema: Value {
    objectSchema(
      properties: nativeSessionSummaryProperties,
      required: ["session_id", "title", "is_indexed"]
    )
  }

  static var listAgentNativeSessions: Tool {
    Tool(
      name: MCPServiceToolName.listAgentNativeSessions.rawValue,
      title: "List Agent native sessions",
      description:
        "List provider-native sessions for one approved project and exact Agent installation. "
        + "Use installation_id from list_agents; Qoder sessions stay bound to their CN or international region.",
      inputSchema: nativeSessionPageInput(required: ["project_id", "installation_id"]),
      annotations: readAnnotations,
      outputSchema: outputSchema(
        properties: [
          "sessions": arraySchema(nativeSessionSummarySchema),
          "next_offset": nullableIntegerSchema(minimum: 0),
        ],
        required: ["sessions"]
      )
    )
  }

  static var readAgentNativeSession: Tool {
    Tool(
      name: MCPServiceToolName.readAgentNativeSession.rawValue,
      title: "Read Agent native session",
      description: "Read one provider-native session transcript page without changing the session.",
      inputSchema: nativeSessionPageInput(
        required: ["project_id", "installation_id", "session_id"]),
      annotations: readAnnotations,
      outputSchema: outputSchema(
        properties: [
          "session_id": stringSchema,
          "messages": arraySchema(
            objectSchema(
              properties: [
                "message_id": stringSchema,
                "role": stringSchema,
                "content": stringSchema,
                "created_at": nullableStringSchema(maximum: 64),
              ],
              required: ["message_id", "role", "content"]
            )),
          "next_offset": nullableIntegerSchema(minimum: 0),
        ],
        required: ["session_id", "messages"]
      )
    )
  }

  static var indexAgentNativeSession: Tool {
    Tool(
      name: MCPServiceToolName.indexAgentNativeSession.rawValue,
      title: "Import Agent native session",
      description:
        "Index one verified native session for continuation by Bridge. This records an exact project and installation binding; it does not start or modify the session.",
      inputSchema: nativeSessionIdentityInput,
      annotations: Tool.Annotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false),
      outputSchema: outputSchema(
        properties: [
          "session_id": stringSchema,
          "project_id": stringSchema,
          "installation_id": stringSchema,
          "region": nullableStringSchema(maximum: 64),
          "indexed_at": stringSchema,
        ],
        required: ["session_id", "project_id", "installation_id", "indexed_at"]
      )
    )
  }

  static var renameAgentNativeSession: Tool {
    Tool(
      name: MCPServiceToolName.renameAgentNativeSession.rawValue,
      title: "Rename Agent native session",
      description:
        "Rename a provider-native session using the selected installation's official API.",
      inputSchema: objectSchema(
        properties: nativeSessionIdentityProperties.merging([
          "title": boundedStringSchema(maximum: 4_096)
        ]) { _, new in new },
        required: ["project_id", "installation_id", "session_id", "title"]),
      annotations: Tool.Annotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false),
      outputSchema: outputSchema(
        properties: nativeSessionSummaryProperties,
        required: ["session_id", "title", "is_indexed"])
    )
  }

  static var deleteAgentNativeSession: Tool {
    Tool(
      name: MCPServiceToolName.deleteAgentNativeSession.rawValue,
      title: "Delete Agent native session",
      description:
        "Permanently delete one provider-native session through its official API. This requires confirmed=true and is refused while a Bridge task is active for the installation and project.",
      inputSchema: objectSchema(
        properties: nativeSessionIdentityProperties.merging(["confirmed": boolSchema]) { _, new in
          new
        },
        required: ["project_id", "installation_id", "session_id", "confirmed"]),
      annotations: Tool.Annotations(
        readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false),
      outputSchema: outputSchema(properties: ["deleted": boolSchema], required: ["deleted"])
    )
  }

  private static var nativeSessionIdentityProperties: [String: Value] {
    [
      "project_id": opaqueProjectIDSchema,
      "installation_id": boundedStringSchema(maximum: 256),
      "session_id": boundedStringSchema(maximum: 256),
    ]
  }

  private static var nativeSessionIdentityInput: Value {
    objectSchema(
      properties: nativeSessionIdentityProperties,
      required: ["project_id", "installation_id", "session_id"])
  }

  private static func nativeSessionPageInput(required: [String]) -> Value {
    objectSchema(
      properties: [
        "project_id": opaqueProjectIDSchema,
        "installation_id": boundedStringSchema(maximum: 256),
        "session_id": boundedStringSchema(maximum: 256),
        "offset": integerSchema(minimum: 0),
        "limit": integerSchema(minimum: 1, maximum: 100),
      ],
      required: required
    )
  }

  private static func nullableIntegerSchema(minimum: Int) -> Value {
    ["type": ["integer", "null"], "minimum": .int(minimum)]
  }
}
