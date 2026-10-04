import BridgeIPC
import BridgeServiceAppCore

extension BridgeServiceAppModel {
  func synchronizeAgentModelScopes() {
    let providers = Set(agentProviders.map(\.providerID)).union(agentModelCatalogScopes.keys)
    for providerID in providers {
      let installationID = agentInstallations.first {
        $0.providerID == providerID && $0.isEnabled && $0.availability == "available"
      }?.installationID
      let scope = AgentModelCatalogScope(
        installationID: installationID, projectID: selectedProjectID)
      guard agentModelCatalogScopes[providerID] != scope else { continue }
      updateAgentModelScope(scope, providerID: providerID)
      guard connectionState == .connected, !stopped else { continue }
      let generation = agentModelCatalogGeneration(for: providerID)
      Task { [weak self] in
        guard let self, self.agentModelCatalogScopes[providerID] == scope,
          self.agentModelCatalogGeneration(for: providerID) == generation,
          self.connectionState == .connected, !self.stopped
        else { return }
        await self.hydrateAgentModelState(
          installationID: installationID, providerID: providerID)
      }
    }
  }

  func updateAgentModelScope(_ scope: AgentModelCatalogScope, providerID: String) {
    guard agentModelCatalogScopes[providerID] != scope else { return }
    agentModelCatalogScopes[providerID] = scope
    incrementAgentModelCatalogGeneration(for: providerID)
    incrementAgentModelRefreshGeneration(for: providerID)
    incrementAgentModelDefaultLoadGeneration(for: providerID)
    agentModelHydrationSuppressions.removeValue(forKey: providerID)
    setAgentModelsRefreshing(false, providerID: providerID)
    setAgentModelsHydrating(false, providerID: providerID)
    setAgentModelOptions([], providerID: providerID)
    setAgentModelRefreshError(nil, providerID: providerID)
  }
}
