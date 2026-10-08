import BridgeIPC

public enum DSHModelCapabilities {
  public static func merging(
    _ existing: [IPCAgentModelSummary], with incoming: [IPCAgentModelSummary],
    selectedModelID: String
  ) -> [IPCAgentModelSummary] {
    guard
      let model = AgentModelCatalogResolver.modelForSelection(
        modelID: selectedModelID, models: incoming)
    else { return existing }
    let previous = AgentModelCatalogResolver.modelForSelection(
      modelID: selectedModelID, models: existing)
    let updated = IPCAgentModelSummary(
      modelID: previous?.modelID ?? model.modelID, displayName: model.displayName,
      compatibleModelIDs: model.compatibleModelIDs,
      supportedReasoningEfforts: model.supportedReasoningEfforts,
      defaultReasoningEffort: model.defaultReasoningEffort,
      reasoningCapabilitiesAvailable: model.reasoningCapabilitiesAvailable,
      isDefaultModel: previous?.isDefaultModel,
      inputModalities: model.inputModalities ?? previous?.inputModalities)
    guard let previous else { return existing + [updated] }
    return existing.map { $0.modelID == previous.modelID ? updated : $0 }
  }
}
