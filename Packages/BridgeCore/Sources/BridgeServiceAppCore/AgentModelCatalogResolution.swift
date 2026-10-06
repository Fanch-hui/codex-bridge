import BridgeAgentCore
import BridgeIPC
import Foundation

public struct AgentModelCatalogResolution {
  public let response: IPCAgentModelsResponse
  public let addedCount: Int
  public let removedCount: Int
  public let defaultWasRemoved: Bool
  public let effortWasRemoved: Bool
  public let canonicalDefaultModelID: String?
}

public enum AgentModelCatalogResolver {
  public static func modelForSelection(
    modelID: String?, models: [IPCAgentModelSummary]
  ) -> IPCAgentModelSummary? {
    if let modelID {
      return AgentModelMatcher.match(
        modelID, in: models, id: { $0.modelID }, compatibleIDs: { $0.compatibleModelIDs })
    }
    return models.first(where: { $0.isDefaultModel == true })
      ?? models.first(where: { !$0.supportedReasoningEfforts.isEmpty }) ?? models.first
  }

  public static func defaultModelWasRemoved(
    _ defaultModel: String?,
    from response: IPCAgentModelsResponse
  ) -> Bool {
    defaultModel.map { model in
      modelForSelection(modelID: model, models: response.models) == nil
    } ?? false
  }

  public static func resolve(
    previousOptions: [IPCAgentModelSummary],
    catalogResponse: IPCAgentModelsResponse,
    response: IPCAgentModelsResponse,
    defaultModel: String?,
    persistedEffort: String?,
    defaultWasRemoved: Bool
  ) -> AgentModelCatalogResolution {
    let previousIDs = Set(previousOptions.map(\.modelID))
    let currentIDs = Set(catalogResponse.models.map(\.modelID))
    let effortModel = modelForSelection(modelID: defaultModel, models: response.models)
    let effortWasRemoved =
      persistedEffort.map { effort in
        effortModel?.reasoningCapabilitiesAvailable != false
          && effortModel?.supportedReasoningEfforts.contains(effort) != true
      } ?? false
    return AgentModelCatalogResolution(
      response: response,
      addedCount: currentIDs.subtracting(previousIDs).count,
      removedCount: previousIDs.subtracting(currentIDs).count,
      defaultWasRemoved: defaultWasRemoved,
      effortWasRemoved: effortWasRemoved,
      canonicalDefaultModelID: defaultModel.flatMap {
        modelForSelection(modelID: $0, models: response.models)?.modelID
      }
    )
  }
}

public enum AgentModelDefaultResolutionError: LocalizedError {
  case piModelUnavailable(modelID: String?)

  public var errorDescription: String? {
    switch self {
    case .piModelUnavailable(let modelID):
      if PiAzureModelMigration.isAzureModelID(modelID) {
        return AgentModelCatalogError.piAzureConfigurationMigrationRequired.errorDescription
      }
      return "Pi 当前目录中没有已保存的模型。默认选择已保留，请检查对应服务商认证及模型配置。"
    }
  }
}
