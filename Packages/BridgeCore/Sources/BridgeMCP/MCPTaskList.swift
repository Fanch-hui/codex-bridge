import Foundation
import MCP

public struct MCPTaskListPage: Codable, Sendable {
  public let schemaVersion: Int
  public let tasks: [MCPTaskListItem]
  public let nextCursor: String?
  public init(tasks: [MCPTaskListItem], nextCursor: String?) {
    self.schemaVersion = 1
    self.tasks = tasks
    self.nextCursor = nextCursor
  }
  enum CodingKeys: String, CodingKey {
    case schemaVersion = "schema_version"
    case tasks
    case nextCursor = "next_cursor"
  }
}

public struct MCPTaskListItem: Codable, Sendable {
  public let taskID: String
  public let projectID: String
  public let providerID: String
  public let status: String
  public let prompt: String
  public let updatedAt: String
  public let queuePosition: Int?
  public let queueOccupantTaskID: String?
  public let queueRequestedAt: String?
  public init(
    taskID: String, projectID: String, providerID: String, status: String, prompt: String,
    updatedAt: String,
    queuePosition: Int? = nil,
    queueOccupantTaskID: String? = nil,
    queueRequestedAt: String? = nil
  ) {
    self.taskID = taskID
    self.projectID = projectID
    self.providerID = providerID
    self.status = status
    self.prompt = prompt
    self.updatedAt = updatedAt
    self.queuePosition = queuePosition
    self.queueOccupantTaskID = queueOccupantTaskID
    self.queueRequestedAt = queueRequestedAt
  }
  enum CodingKeys: String, CodingKey {
    case taskID = "task_id"
    case projectID = "project_id"
    case providerID = "provider_id"
    case status, prompt
    case updatedAt = "updated_at"
    case queuePosition = "queue_position"
    case queueOccupantTaskID = "queue_occupant_task_id"
    case queueRequestedAt = "queue_requested_at"
  }
}

extension MCPServiceToolCatalog {
  static let listTasks = Tool(
    name: MCPServiceToolName.listTasks.rawValue,
    title: "List tasks",
    description:
      "Find Bridge tasks and recover task IDs. Results are ordered by most recently updated task. Use get_task for full details.",
    inputSchema: objectSchema(properties: [
      "project_id": optionalOpaqueProjectIDSchema,
      "cursor": nullableStringSchema(maximum: 2048),
      "limit": integerSchema(minimum: 1, maximum: 100),
    ]), annotations: readAnnotations,
    outputSchema: outputSchema(
      properties: [
        "tasks": arraySchema(
          objectSchema(
            properties: [
              "task_id": stringSchema, "project_id": opaqueProjectIDSchema,
              "provider_id": stringSchema, "status": stringSchema,
              "prompt": stringSchema, "updated_at": stringSchema,
              "queue_position": integerSchema(minimum: 1),
              "queue_occupant_task_id": stringSchema,
              "queue_requested_at": stringSchema,
            ], required: ["task_id", "project_id", "provider_id", "status", "prompt", "updated_at"])
        ),
        "next_cursor": nullableStringSchema(maximum: 2048),
      ], required: ["tasks"])
  )
}

extension MCPServiceToolDispatcher {
  func callListTasks(_ arguments: [String: Value]?) async throws -> CallTool.Result {
    let values = try StrictToolArguments(arguments, allowed: ["project_id", "cursor", "limit"])
    let projectID = try values.optionalIdentifier("project_id", maximumUTF8Bytes: 128)
    let cursor = try values.optionalIdentifier("cursor", maximumUTF8Bytes: 2048)
    let limit = try values.optionalPositiveInteger("limit", maximum: 100) ?? 20
    let deadline = clock.now.advanced(by: deadlines.read)
    let page = try await withToolDeadline(until: deadline) {
      try await service.serviceListTasks(
        projectID: projectID, cursor: cursor, limit: limit, deadline: deadline)
    }
    return try resultEncoder.encode(page)
  }
}
