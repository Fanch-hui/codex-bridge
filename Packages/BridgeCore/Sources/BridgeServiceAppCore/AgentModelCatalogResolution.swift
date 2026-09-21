import BridgeIPC

public struct AgentModelCatalogResolution {
  public let response: IPCAgentModelsResponse
  public let addedCount: Int
  public let removedCount: Int
  public let defaultWasRemoved: Bool
  public let effortWasRemoved: Bool
}

public enum AgentModelCatalogResolver {
  public static func modelForSelection(
    modelID: String?, models: [IPCAgentModelSummary]
  ) -> IPCAgentModelSummary? {
    if let modelID { return models.first(where: { $0.modelID == modelID }) }
    return models.first(where: { $0.isDefaultModel == true })
      ?? models.first(where: { !$0.supportedReasoningEfforts.isEmpty }) ?? models.first
  }

  public static func defaultModelWasRemoved(
    _ defaultModel: String?,
    from response: IPCAgentModelsResponse
  ) -> Bool {
    defaultModel.map { model in
      !response.models.contains(where: { $0.modelID == model })
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
      effortWasRemoved: effortWasRemoved
    )
  }
}
