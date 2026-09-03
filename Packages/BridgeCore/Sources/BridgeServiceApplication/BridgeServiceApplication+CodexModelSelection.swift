import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  struct SelectedModel: Sendable {
    let model: String
    let effort: String
  }

  struct ModelSelections: Sendable {
    let execution: SelectedModel
    let supervisor: SelectedModel?
  }

  func modelSelections(
    submission: MCPServiceTaskSubmission,
    models: [MCPModelSummary]?
  ) async throws -> ModelSelections {
    guard let models, !models.isEmpty else {
      return try uncataloguedModelSelections(submission: submission)
    }
    let configuredExecutionModel = try await settings.string(for: .defaultExecutionModel)
    let configuredExecutionEffort = try await settings.string(for: .defaultExecutionEffort)
    let usesExplicitOverride = submission.modelOverride == true
    let executionModelID =
      (usesExplicitOverride ? submission.executionModel : nil)
      ?? configuredExecutionModel
      ?? models.first(where: \.isDefault)?.modelID
      ?? models[0].modelID
    let execution = try Self.select(
      modelID: executionModelID,
      effort: (usesExplicitOverride ? submission.executionEffort : nil)
        ?? configuredExecutionEffort,
      models: models
    )

    #if os(Windows)
      return ModelSelections(execution: execution, supervisor: nil)
    #endif
    guard try await settings.isSupervisorEnabled() else {
      return ModelSelections(execution: execution, supervisor: nil)
    }

    let explicitSupervisor =
      usesExplicitOverride
      && (submission.supervisorModel != nil
        || submission.supervisorEffort != nil)
    let configuredSupervisorModel = try await settings.string(for: .defaultSupervisorModel)
    let configuredSupervisorEffort = try await settings.string(for: .defaultSupervisorEffort)
    let supervisor: SelectedModel
    if explicitSupervisor {
      guard let model = submission.supervisorModel,
        let effort = submission.supervisorEffort
      else {
        throw BridgeMCPQueryError.contractRejected
      }
      supervisor = try Self.select(modelID: model, effort: effort, models: models)
    } else if let configuredSupervisorModel {
      supervisor = try Self.select(
        modelID: configuredSupervisorModel,
        effort: configuredSupervisorEffort,
        models: models
      )
    } else {
      let recommended =
        models.first(where: { $0.modelID == "gpt-5.6-luna" })
        ?? models.first(where: \.isDefault)
        ?? models[0]
      supervisor = try Self.select(
        modelID: recommended.modelID,
        effort: configuredSupervisorEffort,
        models: models
      )
    }
    return ModelSelections(execution: execution, supervisor: supervisor)
  }

  func resolvedDefaultModelPreferences(
    models: [MCPModelSummary]
  ) async throws -> ServiceModelPreferences {
    guard !models.isEmpty else { throw BridgeMCPQueryError.unavailable }

    let configuredExecutionModel = try await settings.string(for: .defaultExecutionModel)
    let configuredExecutionEffort = try await settings.string(for: .defaultExecutionEffort)
    let executionModelID =
      configuredExecutionModel
      ?? models.first(where: \.isDefault)?.modelID
      ?? models[0].modelID
    let execution = try Self.select(
      modelID: executionModelID,
      effort: configuredExecutionEffort,
      models: models
    )

    let configuredSupervisorModel = try await settings.string(for: .defaultSupervisorModel)
    let configuredSupervisorEffort = try await settings.string(for: .defaultSupervisorEffort)
    let supervisorModelID =
      configuredSupervisorModel
      ?? models.first(where: { $0.modelID == "gpt-5.6-luna" })?.modelID
      ?? models.first(where: \.isDefault)?.modelID
      ?? models[0].modelID
    let supervisor = try Self.select(
      modelID: supervisorModelID,
      effort: configuredSupervisorEffort,
      models: models
    )

    return ServiceModelPreferences(
      executionModel: execution.model,
      executionEffort: execution.effort,
      supervisorModel: supervisor.model,
      supervisorEffort: supervisor.effort,
      accessMode: try await settings.accessMode(),
      fastModeEnabled: try await settings.isFastModeEnabled()
    )
  }

  private func uncataloguedModelSelections(
    submission: MCPServiceTaskSubmission
  ) throws -> ModelSelections {
    guard submission.modelOverride == true else {
      return ModelSelections(
        execution: SelectedModel(
          model: serviceDefaultProviderExecutionModel,
          effort: serviceDefaultProviderExecutionEffort
        ),
        supervisor: nil
      )
    }
    let model = try Self.validatedCodexSelection(
      submission.executionModel,
      fallback: serviceDefaultProviderExecutionModel,
      maximumBytes: 256
    )
    let effort = try Self.validatedCodexSelection(
      submission.executionEffort,
      fallback: serviceDefaultProviderExecutionEffort,
      maximumBytes: 64
    )
    return ModelSelections(
      execution: SelectedModel(model: model, effort: effort),
      supervisor: nil
    )
  }

  private static func validatedCodexSelection(
    _ value: String?,
    fallback: String,
    maximumBytes: Int
  ) throws -> String {
    guard let value else { return fallback }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= maximumBytes,
      !trimmed.contains("\0"),
      trimmed.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw BridgeMCPQueryError.contractRejected
    }
    return trimmed
  }

  static func select(
    modelID: String,
    effort: String?,
    models: [MCPModelSummary]
  ) throws -> SelectedModel {
    guard let model = models.first(where: { $0.modelID == modelID }) else {
      throw BridgeMCPQueryError.contractRejected
    }
    let selectedEffort =
      effort
      ?? model.defaultReasoningEffort
      ?? model.reasoningEfforts.first
    guard let selectedEffort, model.reasoningEfforts.contains(selectedEffort) else {
      throw BridgeMCPQueryError.contractRejected
    }
    return SelectedModel(model: model.modelID, effort: selectedEffort)
  }
}
