import MCP

extension MCPServiceToolCatalog {
  static let listAgentModels = Tool(
    name: MCPServiceToolName.listAgentModels.rawValue,
    title: "List Agent models",
    description:
      "List the native model catalog and reasoning efforts for one registered Agent installation. "
      + "Use installation_id from list_agents. Pass project_id for project-specific models; omitting "
      + "it uses the current Workbench project. Use model_id to resolve reasoning capabilities for "
      + "a selected model, and force_refresh=true to refresh the cached catalog.",
    inputSchema: objectSchema(
      properties: [
        "installation_id": boundedStringSchema(maximum: 256),
        "project_id": optionalOpaqueProjectIDSchema,
        "model_id": nullableStringSchema(maximum: 256),
        "force_refresh": boolSchema,
      ],
      required: ["installation_id"]
    ),
    annotations: readAnnotations,
    outputSchema: outputSchema(
      properties: [
        "installation_id": stringSchema,
        "models": arraySchema(
          objectSchema(
            properties: [
              "model_id": stringSchema,
              "display_name": stringSchema,
              "reasoning_efforts": arraySchema(stringSchema),
              "default_reasoning_effort": nullableStringSchema(maximum: 256),
              "reasoning_capabilities_available": boolSchema,
              "is_default": ["type": ["boolean", "null"]],
            ],
            required: [
              "model_id", "display_name", "reasoning_efforts", "reasoning_capabilities_available",
            ]
          )
        ),
      ],
      required: ["installation_id", "models"]
    )
  )
}
