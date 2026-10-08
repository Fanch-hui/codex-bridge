#if os(Windows) || os(Linux)
  import BridgeIPC
  import BridgeServiceAppCore

  extension WindowsAgentDefaultsModel {
    func refreshDSHModelCapabilities(installationID: String, modelID: String) async {
      let providerID = "deepseek-harness"
      guard connectionState == .connected, !refreshingProviderIDs.contains(providerID),
        installations.contains(where: {
          $0.installationID == installationID && $0.providerID == providerID
            && $0.isEnabled && $0.availability == "available"
        })
      else { return }
      let projectID = workbenchProjectID
      let scope = modelCatalogScope(
        providerID: providerID, installationID: installationID, projectID: projectID)
      modelRefreshGenerations[providerID, default: 0] &+= 1
      let generation = modelRefreshGenerations[providerID, default: 0]
      refreshingProviderIDs.insert(providerID)
      providerErrors[providerID] = nil
      publishDisplay()
      defer {
        if modelRefreshGenerations[providerID] == generation {
          refreshingProviderIDs.remove(providerID)
          publishDisplay()
        }
      }
      do {
        let response = try await client.agentModels(
          installationID: installationID, projectID: projectID, modelID: modelID,
          useStoredDefault: false, forceRefresh: false)
        guard modelRefreshGenerations[providerID] == generation,
          workbenchProjectID == projectID,
          catalogScopes[providerID] == scope
        else { return }
        let catalog = DSHModelCapabilities.merging(
          modelCatalogs[providerID] ?? [], with: response.models, selectedModelID: modelID)
        modelCatalogs[providerID] = catalog
        if selectedProviderID == providerID { models = catalog }
      } catch {
        guard modelRefreshGenerations[providerID] == generation,
          workbenchProjectID == projectID, catalogScopes[providerID] == scope
        else { return }
        providerErrors[providerID] = BridgeServiceErrorMessage.message(error)
      }
    }
  }
#endif
