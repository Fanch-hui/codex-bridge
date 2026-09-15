import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public func serviceCustomInstructions(
    deadline: ContinuousClock.Instant
  ) async throws -> String {
    try Self.checkDeadline(deadline)
    return try await settings.customInstructions()
  }

  public func setServiceCustomInstructions(
    _ instructions: String,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    try await settings.setCustomInstructions(instructions)
  }

  public func serviceModels(
    deadline: ContinuousClock.Instant
  ) async throws -> MCPModelList {
    let models = try await catalog.listModels(deadline: deadline)
    guard !models.models.isEmpty else { return models }
    let preferences = try await resolvedDefaultModelPreferences(models: models.models)
    return Self.modelsWithConfiguredDefault(models, preferences: preferences)
  }

  public func serviceModelPreferences(
    deadline: ContinuousClock.Instant
  ) async throws -> ServiceModelPreferences {
    try await serviceModelCatalog(deadline: deadline).preferences
  }

  public func serviceModelCatalog(
    deadline: ContinuousClock.Instant,
    forceRefresh: Bool = false
  ) async throws -> ServiceModelCatalog {
    try Self.checkDeadline(deadline)
    let models: MCPModelList
    if forceRefresh {
      models = try await catalog.refreshModels(deadline: deadline)
    } else {
      models = try await catalog.listModels(deadline: deadline)
    }
    let preferences = try await resolvedDefaultModelPreferences(models: models.models)
    return ServiceModelCatalog(
      models: Self.modelsWithConfiguredDefault(models, preferences: preferences),
      preferences: preferences
    )
  }

  public func setServiceModelPreferences(
    _ preferences: ServiceModelPreferences,
    deadline: ContinuousClock.Instant
  ) async throws {
    try Self.checkDeadline(deadline)
    let models = try await catalog.listModels(deadline: deadline).models
    _ = try Self.select(
      modelID: preferences.executionModel,
      effort: preferences.executionEffort,
      models: models
    )
    try Self.checkDeadline(deadline)
    try await settings.setModelPreferences(preferences)
  }

  public func setSupervisorEnabled(_ enabled: Bool) async throws {
    guard !enabled else { throw BridgeMCPQueryError.contractRejected }
    try await settings.setSupervisorEnabled(false)
  }

  private static func modelsWithConfiguredDefault(
    _ models: MCPModelList,
    preferences: ServiceModelPreferences
  ) -> MCPModelList {
    MCPModelList(
      models: models.models.map { model in
        MCPModelSummary(
          modelID: model.modelID,
          displayName: model.displayName,
          isDefault: model.modelID == preferences.executionModel,
          reasoningEfforts: model.reasoningEfforts,
          defaultReasoningEffort: model.modelID == preferences.executionModel
            ? preferences.executionEffort : model.defaultReasoningEffort,
          serviceTiers: model.serviceTiers,
          additionalSpeedTiers: model.additionalSpeedTiers
        )
      }
    )
  }
}
