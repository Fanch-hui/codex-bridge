import BridgeIPC
import BridgeServiceAppCore

extension BridgeServiceAppModel {
  func synchronizeAgentModelScopes() {
    let providers = Set(agentProviders.map(\.providerID)).union(agentModelCatalogScopes.keys)
    for providerID in providers {
      let candidates = agentInstallations.filter {
        $0.providerID == providerID && $0.isEnabled && $0.availability == "available"
      }
      let installationID = (candidates.first { $0.isActive == true } ?? candidates.first)?
        .installationID
      let scope = agentModelScope(
        installationID: installationID,
        projectID: selectedProjectID, providerID: providerID)
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

  func agentModelScope(installationID: String?, projectID: String?, providerID: String)
    -> AgentModelCatalogScope
  {
    let desktop = installationID.flatMap { deepSeekDesktopStates[$0] }
    let runtimeKey =
      providerID == "deepseek-harness-desktop"
      ? ["native-desktop", desktop?.profileID ?? ""].joined(separator: "|") : nil
    return AgentModelCatalogScope(
      installationID: installationID,
      projectID: projectID, runtimeKey: runtimeKey)
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
