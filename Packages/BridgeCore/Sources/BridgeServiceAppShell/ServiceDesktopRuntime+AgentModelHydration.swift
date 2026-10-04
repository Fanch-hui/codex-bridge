import BridgeIPC
import BridgeServiceAppCore

extension BridgeServiceAppModel {
  func consumeAgentModelHydrationSuppression(
    providerID: String = "opencode",
    installationID: String?,
    projectID: String?,
    modelID: String?
  ) -> Bool {
    let hydrationID = AgentModelHydrationID(
      providerID: providerID,
      installationID: installationID,
      projectID: projectID,
      modelID: modelID
    )
    guard agentModelHydrationSuppressions[providerID] == hydrationID else {
      agentModelHydrationSuppressions.removeValue(forKey: providerID)
      return false
    }
    agentModelHydrationSuppressions.removeValue(forKey: providerID)
    return true
  }

  func hydrateAgentModelState(
    installationID: String?,
    providerID: String = "opencode"
  ) async {
    let projectID = selectedProjectID
    let normalizedInstallationID = installationID.flatMap { $0.isEmpty ? nil : $0 }
    let scope = AgentModelCatalogScope(
      installationID: normalizedInstallationID,
      projectID: projectID
    )
    updateAgentModelScope(scope, providerID: providerID)
    incrementAgentModelCatalogGeneration(for: providerID)
    let catalogGeneration = agentModelCatalogGeneration(for: providerID)
    incrementAgentModelDefaultLoadGeneration(for: providerID)
    let defaultLoadGeneration = agentModelDefaultLoadGeneration(for: providerID)
    agentModelHydrationGenerations[providerID] = catalogGeneration
    setAgentModelsHydrating(true, providerID: providerID)
    defer {
      if agentModelHydrationGenerations[providerID] == catalogGeneration {
        setAgentModelsHydrating(false, providerID: providerID)
      }
    }

    if let mutation = agentModelDefaultMutationTasks[providerID] {
      await mutation.value
    }
    guard !Task.isCancelled,
      agentModelCatalogScopes[providerID] == scope, selectedProjectID == projectID
    else { return }
    let defaultRevision = agentModelDefaultRevision(for: providerID)
    guard let client = try? currentClient() else { return }

    let persistedDefault = try? await client.agentModelDefault(providerID: providerID)
    let modelResponse: IPCAgentModelsResponse?
    if let installationID = normalizedInstallationID {
      let rawResponse = try? await client.agentModels(
        installationID: installationID,
        projectID: projectID,
        modelID: nil,
        useStoredDefault: false
      )
      if let rawResponse,
        let defaultModel = persistedDefault?.model,
        rawResponse.models.first(where: { $0.modelID == defaultModel })?
          .reasoningCapabilitiesAvailable == false
      {
        modelResponse =
          (try? await client.agentModels(
            installationID: installationID,
            projectID: projectID,
            modelID: defaultModel,
            useStoredDefault: false
          )) ?? rawResponse
      } else {
        modelResponse = rawResponse
      }
    } else {
      modelResponse = nil
    }

    guard !Task.isCancelled,
      agentModelCatalogScopes[providerID] == scope, selectedProjectID == projectID
    else { return }
    if catalogGeneration == agentModelCatalogGeneration(for: providerID), let modelResponse {
      setAgentModelOptions(modelResponse.models, providerID: providerID)
    }
    guard defaultLoadGeneration == agentModelDefaultLoadGeneration(for: providerID),
      defaultRevision == agentModelDefaultRevision(for: providerID),
      let persistedDefault
    else { return }
    applyAgentModelDefault(persistedDefault, providerID: providerID)
  }

}
