import MCP

extension MCPServiceToolCatalog {
  static let waitTask = Tool(
    name: MCPServiceToolName.waitTask.rawValue,
    title: "Wait for task result",
    description:
      "Wait for an existing task from any Agent. After submit_task returns the task ID, normally "
      + "use this tool to wait up to 300 seconds by default. It returns immediately on completion, "
      + "failure, interruption, or a request for approval or user input. terminal carries the saved "
      + "result in task; still_running means execution continues with the same task ID. You may "
      + "call get_task at any time and choose your own checking schedule. Present approval requests "
      + "to the user for resolution in Bridge, and use answer_user_input for pending questions, "
      + "then wait on the same task. Waiting expiry, request cancellation, or connection loss only "
      + "ends this wait; the Agent task continues and Bridge saves its result.",
    inputSchema: objectSchema(
      properties: [
        "task_id": boundedStringSchema(maximum: 128),
        "timeout_seconds": integerSchema(minimum: 1, maximum: 300),
        "recent_event_limit": integerSchema(minimum: 1, maximum: 50),
      ],
      required: ["task_id"]
    ),
    annotations: readAnnotations,
    outputSchema: outputSchema(
      properties: [
        "task": taskSchema,
        "wait_status": [
          "type": "string",
          "enum": ["terminal", "awaiting_approval", "needs_input", "still_running"],
        ],
      ],
      required: ["task", "wait_status"]
    )
  )
}
