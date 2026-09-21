import MCP

extension MCPServiceToolCatalog {
  private static let mutationKindSchema: Value = [
    "type": "string",
    "enum": ["write", "edit", "patch"],
  ]

  private static let mutationFileSchema = objectSchema(
    properties: [
      "relative_path": stringSchema,
      "before_revision": [
        "type": ["object", "null"],
        "properties": [
          "sha256": stringSchema,
          "byte_count": integerSchema(minimum: 0),
        ],
        "required": ["sha256", "byte_count"],
      ],
      "after_revision": objectSchema(
        properties: [
          "sha256": stringSchema,
          "byte_count": integerSchema(minimum: 0),
        ],
        required: ["sha256", "byte_count"]
      ),
      "bounded_diff": objectSchema(
        properties: [
          "removed_lines": arraySchema(stringSchema),
          "added_lines": arraySchema(stringSchema),
          "truncated": boolSchema,
          "byte_count": integerSchema(minimum: 0),
        ],
        required: ["removed_lines", "added_lines", "truncated", "byte_count"]
      ),
    ],
    required: ["relative_path", "after_revision", "bounded_diff"]
  )

  private static let mutationPreviewOutputSchema = outputSchema(
    properties: [
      "receipt_type": receiptTypeSchema(["file_mutation_preview"]),
      "operation_id": stringSchema,
      "project_id": stringSchema,
      "kind": stringSchema,
      "changed_files": arraySchema(mutationFileSchema),
      "prepared_at": stringSchema,
    ],
    required: [
      "receipt_type", "operation_id", "project_id", "kind", "changed_files", "prepared_at",
    ]
  )

  private static let mutationReceiptOutputSchema = outputSchema(
    properties: [
      "receipt_type": receiptTypeSchema(["file_mutation"]),
      "operation_id": stringSchema,
      "project_id": stringSchema,
      "kind": stringSchema,
      "status": stringSchema,
      "changed_files": arraySchema(mutationFileSchema),
      "timestamp": stringSchema,
    ],
    required: [
      "receipt_type", "operation_id", "project_id", "kind", "status", "changed_files",
      "timestamp",
    ]
  )

  static let directPreviewProjectMutation = Tool(
    name: MCPServiceToolName.directPreviewProjectMutation.rawValue,
    title: "Preview Direct project mutation",
    description:
      "Validate and preview a Direct project file mutation without writing. Supports write, edit, "
      + "and patch. Directory, move, and delete path operations are not supported by this preview.",
    inputSchema: objectSchema(
      properties: [
        "project_id": opaqueProjectIDSchema,
        "kind": mutationKindSchema,
        "relative_path": nullableStringSchema(maximum: 1_024),
        "mode": nullableStringSchema(maximum: 16),
        "content": nullableStringSchema(maximum: 256 * 1_024),
        "expected_sha256": nullableStringSchema(maximum: 64),
        "create_parents": boolSchema,
        "old_text": nullableStringSchema(maximum: 256 * 1_024),
        "new_text": nullableStringSchema(maximum: 256 * 1_024),
        "expected_replacements": integerSchema(minimum: 1, maximum: 1_000),
        "patch": nullableStringSchema(maximum: 256 * 1_024),
        "client_request_id": nullableStringSchema(maximum: 512),
      ],
      required: ["project_id", "kind"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: true,
      destructiveHint: false,
      idempotentHint: false,
      openWorldHint: false
    ),
    outputSchema: mutationPreviewOutputSchema
  )

  static let directApplyProjectMutation = Tool(
    name: MCPServiceToolName.directApplyProjectMutation.rawValue,
    title: "Apply Direct project mutation",
    description:
      "Apply a previously previewed Direct project file mutation after the normal file-write "
      + "approval and workspace lease checks. Pass the operation_id returned by preview.",
    inputSchema: objectSchema(
      properties: [
        "operation_id": boundedStringSchema(maximum: 128),
        "client_request_id": nullableStringSchema(maximum: 512),
      ],
      required: ["operation_id"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: false,
      openWorldHint: false
    ),
    outputSchema: mutationReceiptOutputSchema
  )

  static let directUndoProjectMutation = Tool(
    name: MCPServiceToolName.directUndoProjectMutation.rawValue,
    title: "Undo Direct project mutation",
    description:
      "Undo a completed Direct project file mutation. The service only restores files when their "
      + "current revision still equals the operation's after revision; later edits return a conflict.",
    inputSchema: objectSchema(
      properties: [
        "operation_id": boundedStringSchema(maximum: 128),
        "client_request_id": nullableStringSchema(maximum: 512),
      ],
      required: ["operation_id"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: false,
      destructiveHint: true,
      idempotentHint: false,
      openWorldHint: false
    ),
    outputSchema: mutationReceiptOutputSchema
  )
}
