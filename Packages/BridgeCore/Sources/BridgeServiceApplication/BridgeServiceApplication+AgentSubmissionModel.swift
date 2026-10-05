import BridgeAgentCore
import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

struct ServiceAgentSubmissionModel: Sendable {
  let descriptor: AgentModelDescriptor?
  let executionModel: String
  let executionEffort: String
}

extension BridgeServiceApplication {
  func resolveAgentSubmissionModel(
    context: ServiceAgentSubmissionContext, project: ServiceProjectRecord
  ) async throws -> ServiceAgentSubmissionModel {
    let modelCatalog: [AgentModelDescriptor]?
    if context.supportsModelSelection {
      modelCatalog = try? await serviceAgentModelCatalog(
        registry: context.registry,
        installationID: context.record.id,
        projectRoot: project.root.canonicalPath,
        selectedModelID: Self.agentCatalogModelID(
          providerID: context.policy.providerID, modelID: context.resolvedModel)
      )
    } else {
      modelCatalog = nil
    }
    let selectedDescriptor = Self.agentModelDescriptor(
      providerID: context.policy.providerID, modelID: context.resolvedModel,
      catalog: modelCatalog ?? [])
    if context.defaults.requiresKnownModel, context.resolvedModel != nil, selectedDescriptor == nil
    {
      throw BridgeMCPQueryError.unavailable
    }
    let executionEffort: String
    if let requestedEffort = context.requestedEffort {
      guard modelCatalog != nil else { throw BridgeMCPQueryError.unavailable }
      guard selectedDescriptor?.supportedReasoningEfforts.contains(requestedEffort) == true else {
        throw BridgeMCPQueryError.contractRejected
      }
      executionEffort = requestedEffort
    } else if let configuredEffort = context.configuredEffort,
      selectedDescriptor?.supportedReasoningEfforts.contains(configuredEffort) == true
    {
      executionEffort = configuredEffort
    } else {
      executionEffort = serviceDefaultProviderExecutionEffort
    }
    return ServiceAgentSubmissionModel(
      descriptor: selectedDescriptor,
      executionModel: context.supportsModelSelection
        ? selectedDescriptor?.id ?? context.resolvedModel ?? serviceDefaultProviderExecutionModel
        : serviceDefaultProviderExecutionModel,
      executionEffort: executionEffort)
  }

  static func agentModelDescriptor(
    providerID: AgentProviderID, modelID: String?, catalog: [AgentModelDescriptor]
  ) -> AgentModelDescriptor? {
    if let modelID {
      return catalog.first(where: { $0.id == modelID })
        ?? catalog.first(where: {
          $0.id == agentCatalogModelID(providerID: providerID, modelID: modelID)
        })
    }
    if providerID == .qoder { return catalog.first(where: { $0.isDefaultModel == true }) }
    return catalog.first(where: { !$0.supportedReasoningEfforts.isEmpty })
  }

  static func agentCatalogModelID(providerID: AgentProviderID, modelID: String?) -> String? {
    guard providerID == .deepSeekHarness, let modelID, modelID.hasPrefix("opencode-go/") else {
      return modelID
    }
    return String(modelID.dropFirst("opencode-go/".count))
  }

}
