import BridgeIPC
import BridgeServiceAppCore

extension BridgeServiceAppModel {
  @discardableResult
  func refreshDSHModelCapabilities(installationID: String, modelID: String) -> Task<Void, Never>? {
    let providerID = "deepseek-harness"
    guard !agentModelRefreshingProviders.contains(providerID) else { return nil }
    let projectID = selectedProjectID
    let scope = agentModelScope(
      installationID: installationID, projectID: projectID, providerID: providerID)
    updateAgentModelScope(scope, providerID: providerID)
    incrementAgentModelRefreshGeneration(for: providerID)
    let generation = agentModelRefreshGeneration(for: providerID)
    let catalogGeneration = agentModelCatalogGeneration(for: providerID)
    setAgentModelsRefreshing(true, providerID: providerID)
    setAgentModelRefreshError(nil, providerID: providerID)
    return Task { [weak self] in
      guard let self else { return }
      defer {
        if agentModelRefreshGeneration(for: providerID) == generation {
          setAgentModelsRefreshing(false, providerID: providerID)
        }
      }
      do {
        let response = try await currentClient().agentModels(
          installationID: installationID, projectID: projectID, modelID: modelID,
          useStoredDefault: false, forceRefresh: false)
        guard selectedProjectID == projectID, agentModelCatalogScopes[providerID] == scope,
          agentModelRefreshGeneration(for: providerID) == generation,
          agentModelCatalogGeneration(for: providerID) == catalogGeneration
        else { return }
        setAgentModelOptions(
          DSHModelCapabilities.merging(
            agentModelOptions(for: providerID), with: response.models, selectedModelID: modelID),
          providerID: providerID)
      } catch {
        guard selectedProjectID == projectID, agentModelCatalogScopes[providerID] == scope,
          agentModelRefreshGeneration(for: providerID) == generation
        else { return }
        setAgentModelRefreshError(Self.message(error), providerID: providerID)
      }
    }
  }
}
