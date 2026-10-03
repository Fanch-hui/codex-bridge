import MCP

extension MCPServiceToolDispatcher {
  func callListAgentModels(_ arguments: [String: Value]?) async throws -> CallTool.Result {
    let values = try StrictToolArguments(
      arguments,
      allowed: ["installation_id", "project_id", "model_id", "force_refresh"],
      required: ["installation_id"]
    )
    let installationID = try values.requiredIdentifier("installation_id", maximumUTF8Bytes: 256)
    let projectID = try values.optionalIdentifier("project_id", maximumUTF8Bytes: 128)
    let modelID = try values.optionalIdentifier("model_id", maximumUTF8Bytes: 256)
    let forceRefresh = try values.optionalBoolean("force_refresh") ?? false
    let deadline = clock.now.advanced(by: deadlines.read)
    let list = try await withToolDeadline(until: deadline) {
      try await service.serviceAgentModels(
        installationID: installationID,
        projectID: projectID,
        modelID: modelID,
        forceRefresh: forceRefresh,
        deadline: deadline
      )
    }
    return try resultEncoder.encode(ListAgentModelsOutput(list))
  }
}
