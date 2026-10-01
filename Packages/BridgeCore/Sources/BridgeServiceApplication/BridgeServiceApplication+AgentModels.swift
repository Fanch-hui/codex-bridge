import BridgeAgentCore
import BridgeMCP

extension BridgeServiceApplication {
  public func serviceAgentModels(
    installationID: String,
    projectID: String?,
    modelID: String?,
    forceRefresh: Bool,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPAgentModelList {
    let models = try await serviceListAgentModels(
      installationID: AgentInstallationID(rawValue: installationID),
      projectID: projectID,
      modelID: modelID,
      useStoredDefault: false,
      forceRefresh: forceRefresh,
      deadline: deadline
    )
    return MCPAgentModelList(
      installationID: installationID,
      models: models.map {
        MCPAgentModelSummary(
          modelID: $0.modelID,
          displayName: $0.displayName,
          reasoningEfforts: $0.supportedReasoningEfforts,
          defaultReasoningEffort: $0.defaultReasoningEffort,
          reasoningCapabilitiesAvailable: $0.reasoningCapabilitiesAvailable,
          isDefault: $0.isDefaultModel
        )
      }
    )
  }
}
