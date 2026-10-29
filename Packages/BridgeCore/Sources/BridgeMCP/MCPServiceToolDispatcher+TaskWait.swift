import Foundation
import MCP

enum MCPTaskWaitBudget {
  static let standardSeconds = 300
  // Tunnel's 120-second request limit includes queueing and response transport.
  static let tunnelSeconds = 90

  static func effectiveSeconds(requested: Int?, clientID: MCPClientID) -> Int {
    let limit = clientID == .chatGPT ? tunnelSeconds : standardSeconds
    return min(requested ?? limit, limit)
  }
}

extension MCPServiceToolDispatcher {
  func callWaitTask(_ arguments: [String: Value]?) async throws -> CallTool.Result {
    let values = try StrictToolArguments(
      arguments,
      allowed: ["task_id", "timeout_seconds", "recent_event_limit"],
      required: ["task_id"]
    )
    let taskID = try values.requiredIdentifier("task_id", maximumUTF8Bytes: 128)
    let requestedTimeout = try values.optionalPositiveInteger(
      "timeout_seconds", maximum: MCPTaskWaitBudget.standardSeconds)
    let timeout = MCPTaskWaitBudget.effectiveSeconds(
      requested: requestedTimeout, clientID: clientID)
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
