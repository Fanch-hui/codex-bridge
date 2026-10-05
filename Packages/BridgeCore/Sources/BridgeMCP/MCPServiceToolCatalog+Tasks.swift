import MCP

extension MCPServiceToolCatalog {
  static let runSkillAction = Tool(
    name: MCPServiceToolName.runSkillAction.rawValue,
    title: "Run skill action",
    description:
      "Run a discovered Skill script through the project's existing Direct command policy. "
      + "Use only when the user explicitly requests local Skill script execution. This is not "
      + "a general command execution tool. Do not use it for pwd, git, swift, xcodebuild, or "
      + "arbitrary scripts; use direct_exec_project_command instead.",
    inputSchema: objectSchema(
      properties: [
        "skill_name": boundedStringSchema(maximum: 128),
        "action_name": boundedStringSchema(maximum: 128),
        "arguments": arraySchema(boundedStringSchema(maximum: 4_096)),
        "project_id": opaqueProjectIDSchema,
        "yield_time_ms": integerSchema(minimum: 0, maximum: 60_000),
        "timeout_ms": integerSchema(minimum: 1, maximum: 3_600_000),
        "client_request_id": nullableStringSchema(maximum: 512),
      ],
      required: ["skill_name", "action_name", "project_id"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: false,
      destructiveHint: true,
      idempotentHint: false,
      openWorldHint: false
    ),
    outputSchema: skillActionOutputSchema
  )

  static let getTask = Tool(
    name: MCPServiceToolName.getTask.rawValue,
    title: "Get task",
    description:
      "Read task state, lifecycle events, recent provider activity, result. "
      + "While running, recent_activity exposes bounded reasoning, text and tool lifecycle updates, "
      + "recent_activity_available reports whether that projection could be read, and updated_at "
      + "reflects the latest persisted provider activity. After submit_task returns "
      + "awaiting_local_approval, present the request for local approval. A denial returns failed "
      + "with failure_code local_approval_denied. You may query get_task at any time, choosing "
      + "the timing yourself. For a submitted task, normally use wait_task first to wait for a result. "
      + "wait_policy retains compatibility guidance without a mandatory polling delay. Only a terminal "
      + "status is authoritative; unchanged updated_at or empty recent_activity does not indicate failure. "
      + "When pending_user_input is present, use answer_user_input with its input_id and question IDs; "
      + "this is a user answer channel, separate from tool permission approval.",
    inputSchema: objectSchema(
      properties: [
        "task_id": boundedStringSchema(maximum: 128),
        "recent_event_limit": integerSchema(minimum: 1, maximum: 50),
      ],
      required: ["task_id"]
    ),
    annotations: readAnnotations,
    outputSchema: outputSchema(
      properties: ["task": taskSchema],
      required: ["task"]
    )
  )

  static let answerUserInput = Tool(
    name: MCPServiceToolName.answerUserInput.rawValue,
    title: "Answer agent question",
    description:
      "Answer one structured question currently pending on a provider task. get_task exposes the "
      + "exact input_id, question IDs, answer choices and input kinds. Send answers as question ID "
      + "to string-array mappings, or set cancelled=true with no answers. Cancellation reaches the "
      + "provider as cancellation and never fabricates a default answer. This does not approve or "
      + "deny a tool permission request.",
    inputSchema: objectSchema(
      properties: [
        "task_id": boundedStringSchema(maximum: 128),
        "input_id": boundedStringSchema(maximum: 128),
        "answers": [
          "type": ["object", "null"],
          "maxProperties": 16,
          "additionalProperties": [
            "type": "array",
            "maxItems": 32,
            "items": boundedStringSchema(maximum: 4 * 1_024),
          ],
        ],
        "cancelled": boolSchema,
      ],
      required: ["task_id", "input_id", "cancelled"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: false,
      openWorldHint: false
    ),
    outputSchema: mutationOutputSchema
  )

  static let submitTask = Tool(
    name: MCPServiceToolName.submitTask.rawValue,
    title: "Submit task",
    description:
      "Create a provider task; Codex remains the default provider. ChatGPT and Qwen submissions "
      + "must contain the user's concrete task, not the global custom instructions that guide "
      + "ChatGPT or Qwen. Do not copy or paraphrase those instructions into the Agent prompt "
      + "unless the user's current request explicitly asks for that content. "
      + "Built-in Bridge instructions stay with the MCP client and must never be included in the Agent prompt. "
      + "They wait for the local user to approve the provider invocation in Codex Bridge before "
      + "execution starts. Return immediately with "
      + "a task_id and current status, then normally use wait_task to await the result and observe "
      + "approval, execution, or an explicit local_approval_denied result. Risky Codex operations "
      + "can still require additional local approval after execution starts. "
      + "Codex is the default execution path. Prefer this tool unless the user explicitly asked "
      + "the MCP client to modify files or run commands directly. Omit project_id to use the "
      + "project currently selected in the Codex Bridge workbench; an explicit project_id overrides "
      + "that default. Omit all model and effort fields unless the user explicitly requests a "
      + "different model for this task; omitted values use the defaults configured in Codex Bridge. "
      + "Model and effort fields are applied only when model_override is true. "
      + "Task permissions are selected by the local user in the Workbench: read-only or full. "
      + "Full includes file writes and network access. This tool uses that selection and cannot override it. "
      + "Set provider_id to route the task to another registered agent provider (for example "
      + "opencode, deepseek-harness, pi, or qoder). Qoder uses its registered regional SDK and CLI. "
      + "For an image-capable Pi or Qoder model, attachment_paths may list up to eight image paths "
      + "relative to the selected project. Include only files the user explicitly chose; Bridge "
      + "validates and binds their content before scheduling. Do not send image bytes or base64. "
      + "Qoder sessions and defaults stay bound to the selected installation and region; never switch "
      + "regions to recover a session. Its tool approvals use the local app and its follow-up input is queued. "
      + "Pi uses an exact Bridge-bound session and native RPC. "
      + "Pi steer_task queues a follow-up; model IDs and thinking levels must come from its model catalog. "
      + "Pi file mutations and shell commands require local approval. Its managed read-only mode disables "
      + "write and shell tools; shell execution requires full mode. "
      + "These are extension tool controls, not an operating-system filesystem or network sandbox. "
      + "DeepSeek Harness supports "
      + "full tasks through its native tools. It cannot enforce read-only tasks without network access. To continue a completed session, "
      + "pass its provider_session_id as thread_id when lifecycle.session_continue is available. Use an explicitly requested model, effort, "
      + "or Skill only when it is supported by the registered installation. "
      + "DeepSeek Harness uses its verified native tool composition; Web, network, MCP, file, command, "
      + "and subagent work should be routed to it when the registered installation exposes those "
      + "capabilities. Its execution-time permission requests are surfaced for local approval. "
      + "OpenCode uses a restricted read-only agent for read-only tasks and native Build for full tasks. "
      + "OpenCode network execution follows native permissions. OpenCode supports model override through the same model_override rule as "
      + "Codex. For OpenCode, execution_effort accepts only the selected model's ACP effort values; "
      + "when omitted, Bridge uses the saved OpenCode default when supported and otherwise the Provider default. "
      + "For OpenCode, skill fields must be omitted. To continue an OpenCode conversation, pass the "
      + "provider_session_id returned by get_task as thread_id; Bridge resumes or loads that exact "
      + "ACP session in the selected project. For Antigravity, set provider_id=antigravity; it "
      + "uses the registered official agy stream-json installation for full tasks in native accept-edits mode. "
      + "It cannot enforce read-only tasks without network access. "
      + "Model selection, including effort encoded in the model ID, and session continuation are "
      + "available only when list_agents reports the corresponding effective capability; thread_id "
      + "must be a prior Bridge-bound Antigravity conversation from the same project and installation. "
      + "steer_task queues follow-up input on the same Antigravity session after the current prompt, "
      + "not real-time insertion. Bridge can inject an explicitly requested skill_name. Network and sandboxed tools follow agy's native policy; Bridge "
      + "must not reject a task solely because it requests network access. A provider permission denial "
      + "is reported as task failure. After receiving the task ID, normally call wait_task, which "
      + "waits up to 300 seconds by default and returns as soon as the task finishes or needs approval "
      + "or user input. If it returns still_running, choose when to query get_task for status and results. "
      + "get_task remains available at any time. A wait ending or a client disconnect does not stop "
      + "the task; Bridge saves its result. wait_policy remains compatible without enforcing a polling delay. "
      + "External Provider network execution is Provider-native. Full mode authorizes writes and network use; "
      + "read-only mode restricts file mutation and network-capable tools where the Provider supports enforcement. "
      + "Bridge controls task admission and local start approval without wrapping Agent processes in an "
      + "operating-system filesystem or network sandbox. Never "
      + "treat a non-terminal status or unchanged "
      + "updated_at as failure.",
    inputSchema: objectSchema(
      properties: [
        "project_id": optionalOpaqueProjectIDSchema,
        "prompt": boundedStringSchema(maximum: 32 * 1_024),
        "skill_name": nullableStringSchema(maximum: 128),
        "skill_names": [
          "type": "array", "maxItems": .int(16),
          "items": boundedStringSchema(maximum: 128),
        ],
        "thread_id": nullableStringSchema(maximum: 1_024),
        "provider_id": nullableStringSchema(
          maximum: 64,
          description:
            "Omit for Codex. Set to opencode, deepseek-harness, antigravity, pi, or qoder only when the user explicitly selected a locally registered installation; list_agents shows availability, effective capabilities, and enforcement."
        ),
        "installation_id": nullableStringSchema(
          maximum: 256,
          description:
            "Optional exact registered installation for the chosen provider; omit to let Bridge pick its enabled installation."
        ),
        "execution_model": nullableStringSchema(
          maximum: 256,
          description:
            "Omit to use the Codex Bridge default or the selected provider default. For registered external providers, use only a model advertised by the selected installation's catalog when selection.model is effective."
        ),
        "execution_effort": nullableStringSchema(
          maximum: 64,
          description:
            "Omit to use the selected provider default effort. For OpenCode, DeepSeek Harness, or Pi, set only a value advertised for the selected model when the user explicitly requests a per-task override and selection.effort is effective; external providers require model_override=true. Antigravity effort is part of the model ID, so omit this field."
        ),
        "model_override": [
          "type": ["boolean", "null"],
          "description":
            "Set true only when the user explicitly requests a per-task model or effort override. Otherwise omit; supplied model fields are ignored for compatibility.",
        ],
        "acceptance_criteria": [
          "type": "array",
          "maxItems": 32,
          "items": boundedStringSchema(maximum: 4_096),
        ],
        "client_request_id": nullableStringSchema(maximum: 512),
        "queue_if_busy": [
          "type": "boolean",
          "description":
            "When true, a full task waits in the durable project queue if another write task is active. The default false preserves immediate busy responses.",
        ],
        "attachment_paths": [
          "type": "array",
          "maxItems": 8,
          "description":
            "Optional project-relative paths for images the user explicitly selected. Pi or Qoder accepts these only when the selected model explicitly advertises image input. Use paths such as assets/diagram.png; do not send file contents or base64.",
          "items": boundedStringSchema(maximum: 2_048),
        ],
      ],
      required: ["prompt"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: true,
      openWorldHint: false
    ),
    outputSchema: outputSchema(
      properties: [
        "receipt_type": receiptTypeSchema(["provider_task"]),
        "task_id": stringSchema,
        "status": stringSchema,
        "reused_existing_task": boolSchema,
        "local_approval_required": boolSchema,
        "wait_policy": taskWaitPolicySchema,
      ],
      required: [
        "receipt_type", "task_id", "status", "reused_existing_task",
        "local_approval_required", "wait_policy",
      ]
    )
  )

  static let steerTask = Tool(
    name: MCPServiceToolName.steerTask.rawValue,
    title: "Steer task",
    description:
      "Send bounded corrective input to the exact active provider run. Send only the user's concrete correction, not global custom instructions for ChatGPT or Qwen. Built-in Bridge instructions stay with the MCP client and must never be included in Agent input. The default queued mode preserves existing behavior. For DeepSeek Harness, mode=interrupt-current-then-continue cancels only the current prompt and sends the correction on the same session without terminating the task. Other external providers currently accept queued mode only.",
    inputSchema: objectSchema(
      properties: [
        "task_id": boundedStringSchema(maximum: 128),
        "expected_turn_id": boundedStringSchema(maximum: 1_024),
        "input": boundedStringSchema(maximum: 32 * 1_024),
        "mode": [
          "type": "string",
          "enum": ["queued", "interrupt-current-then-continue"],
          "description":
            "Delivery mode. Omit or use queued for compatibility. interrupt-current-then-continue is available only when list_agents reports lifecycle.steer_interrupt_and_continue.",
        ],
      ],
      required: ["task_id", "expected_turn_id", "input"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: false,
      destructiveHint: false,
      idempotentHint: false,
      openWorldHint: false
    ),
    outputSchema: mutationOutputSchema
  )

  static let interruptTask = Tool(
    name: MCPServiceToolName.interruptTask.rawValue,
    title: "Interrupt task",
    description:
      "Request interruption of the exact active provider run. For Codex, expected_turn_id is the active Turn ID; for OpenCode, DeepSeek Harness, and Antigravity, use provider_run_id from get_task.",
    inputSchema: objectSchema(
      properties: [
        "task_id": boundedStringSchema(maximum: 128),
        "expected_turn_id": boundedStringSchema(maximum: 1_024),
      ],
      required: ["task_id"]
    ),
    annotations: Tool.Annotations(
      readOnlyHint: false,
      destructiveHint: true,
      idempotentHint: false,
      openWorldHint: false
    ),
    outputSchema: mutationOutputSchema
  )

  static let mutationOutputSchema = outputSchema(
    properties: [
      "receipt_type": receiptTypeSchema(["task_mutation"]),
      "task_id": stringSchema,
      "status": stringSchema,
      "accepted": boolSchema,
    ],
    required: ["receipt_type", "task_id", "status", "accepted"]
  )
}
