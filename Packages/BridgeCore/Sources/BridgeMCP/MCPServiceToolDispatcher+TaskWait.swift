import Foundation
import MCP

extension MCPServiceToolDispatcher {
  func callWaitTask(_ arguments: [String: Value]?) async throws -> CallTool.Result {
    let values = try StrictToolArguments(
      arguments,
      allowed: ["task_id", "timeout_seconds", "recent_event_limit"],
      required: ["task_id"]
    )
    let taskID = try values.requiredIdentifier("task_id", maximumUTF8Bytes: 128)
    let timeout = try values.optionalPositiveInteger("timeout_seconds", maximum: 300) ?? 300
    let eventLimit = try values.optionalPositiveInteger("recent_event_limit", maximum: 50) ?? 20
    let deadline = clock.now.advanced(by: .seconds(timeout + 5))
    let result = try await withToolDeadline(until: deadline) {
      try await service.serviceWaitTask(
        taskID: taskID,
        timeoutSeconds: timeout,
        recentEventLimit: eventLimit,
        deadline: deadline
      )
    }
    try validate(result.task, requestedTaskID: taskID, eventLimit: eventLimit)
    return try resultEncoder.encode(result)
  }
}
