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
    let scope = agentModelScope(
      installationID: normalizedInstallationID,
      projectID: projectID, providerID: providerID)
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

    let persistedDefault: IPCAgentModelDefaultResponse?
    let defaultReadError: String?
    do {
      persistedDefault = try await client.agentModelDefault(providerID: providerID)
      defaultReadError = nil
    } catch {
      persistedDefault = nil
      defaultReadError = Self.message(error)
    }
    guard !Task.isCancelled,
      agentModelCatalogScopes[providerID] == scope, selectedProjectID == projectID
    else { return }
    if defaultLoadGeneration == agentModelDefaultLoadGeneration(for: providerID),
      defaultRevision == agentModelDefaultRevision(for: providerID), let persistedDefault
    {
      applyAgentModelDefault(persistedDefault, providerID: providerID)
    }
    let hydration = await loadAgentModelHydration(
      client: client, installationID: normalizedInstallationID, projectID: projectID,
      persistedDefault: persistedDefault)
    let modelResponse = hydration.response

    guard !Task.isCancelled,
      agentModelCatalogScopes[providerID] == scope, selectedProjectID == projectID
    else { return }
    if catalogGeneration == agentModelCatalogGeneration(for: providerID), let modelResponse {
      setAgentModelOptions(modelResponse.models, providerID: providerID)
    }
    guard defaultLoadGeneration == agentModelDefaultLoadGeneration(for: providerID),
      defaultRevision == agentModelDefaultRevision(for: providerID)
    else { return }
    if catalogGeneration == agentModelCatalogGeneration(for: providerID) {
      if let error = defaultReadError ?? hydration.error {
        setAgentModelRefreshError(error, providerID: providerID)
      } else if normalizedInstallationID == nil || modelResponse != nil {
        setAgentModelRefreshError(nil, providerID: providerID)
      }
    }
    guard let persistedDefault else { return }
    if providerID == "pi", let modelID = persistedDefault.model, let modelResponse,
      let canonical = AgentModelCatalogResolver.modelForSelection(
        modelID: modelID, models: modelResponse.models),
      canonical.modelID != modelID
    {
      do {
        let corrected = try await client.setAgentDefaults(
          providerID: providerID, model: canonical.modelID,
          permissionMode: persistedDefault.permissionMode,
          effort: canonical.reasoningCapabilitiesAvailable == false
            || canonical.supportedReasoningEfforts.contains(persistedDefault.effort ?? "")
            ? persistedDefault.effort : nil)
        guard defaultLoadGeneration == agentModelDefaultLoadGeneration(for: providerID),
          defaultRevision == agentModelDefaultRevision(for: providerID),
          agentModelCatalogScopes[providerID] == scope, selectedProjectID == projectID
        else { return }
        incrementAgentModelDefaultRevision(for: providerID)
        applyAgentModelDefault(corrected, providerID: providerID)
      } catch {
        setAgentModelRefreshError(Self.message(error), providerID: providerID)
      }
    } else {
      applyAgentModelDefault(persistedDefault, providerID: providerID)
      if providerID == "pi", let modelResponse,
        AgentModelCatalogResolver.defaultModelWasRemoved(
          persistedDefault.model, from: modelResponse)
      {
        setAgentModelRefreshError(
          AgentModelDefaultResolutionError.piModelUnavailable(modelID: persistedDefault.model)
            .errorDescription,
          providerID: providerID)
      }
    }
  }

  private func loadAgentModelHydration(
    client: any BridgeServiceClientProtocol,
    installationID: String?,
    projectID: String?,
    persistedDefault: IPCAgentModelDefaultResponse?
  ) async -> (response: IPCAgentModelsResponse?, error: String?) {
    guard let installationID else { return (nil, nil) }
    var response: IPCAgentModelsResponse?
    do {
      let catalog = try await client.agentModels(
        installationID: installationID, projectID: projectID, modelID: nil,
        useStoredDefault: false)
      response = catalog
      if let defaultModel = persistedDefault?.model,
        AgentModelCatalogResolver.modelForSelection(
          modelID: defaultModel, models: catalog.models)?.reasoningCapabilitiesAvailable == false
      {
        response = try await client.agentModels(
          installationID: installationID, projectID: projectID, modelID: defaultModel,
          useStoredDefault: false)
      }
      return (response, nil)
    } catch {
      return (response, Self.message(error))
    }
  }

}
