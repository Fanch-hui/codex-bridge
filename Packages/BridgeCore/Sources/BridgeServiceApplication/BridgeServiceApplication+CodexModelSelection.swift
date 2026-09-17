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
    return ModelSelections(execution: execution, supervisor: nil)
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

    let supervisorModel = try await settings.string(for: .defaultSupervisorModel) ?? ""
    let supervisorEffort = try await settings.string(for: .defaultSupervisorEffort) ?? ""

    return ServiceModelPreferences(
      executionModel: execution.model,
      executionEffort: execution.effort,
      supervisorModel: supervisorModel,
      supervisorEffort: supervisorEffort,
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
