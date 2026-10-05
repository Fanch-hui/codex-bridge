import BridgeIPC
import BridgeServiceAppCore
import Foundation

extension BridgeServiceAppModel {
  func refreshAgentModelCatalog(
    installationID: String?,
    providerID: String = "opencode",
    forceRefresh: Bool = true
  ) {
    guard !agentModelRefreshingProviders.contains(providerID) else { return }
    guard let installationID, !installationID.isEmpty else {
      setAgentModelRefreshError(
        "暂无已启用且可用的 \(agentProviderName(providerID)) 安装。",
        providerID: providerID
      )
      return
    }

    updateAgentModelScope(
      AgentModelCatalogScope(installationID: installationID, projectID: selectedProjectID),
      providerID: providerID)
    incrementAgentModelCatalogGeneration(for: providerID)
    let catalogGeneration = agentModelCatalogGeneration(for: providerID)
    incrementAgentModelRefreshGeneration(for: providerID)
    let refreshGeneration = agentModelRefreshGeneration(for: providerID)
    incrementAgentModelDefaultLoadGeneration(for: providerID)
    let previousMutation = agentModelDefaultMutationTasks[providerID]
    let projectID = selectedProjectID
    setAgentModelsHydrating(false, providerID: providerID)
    setAgentModelsRefreshing(
      forceRefresh || agentModelOptions(for: providerID).isEmpty, providerID: providerID)
    setAgentModelRefreshError(nil, providerID: providerID)

    Task { [weak self, previousMutation] in
      guard let self else { return }
      await self.performAgentModelCatalogRefresh(
        installationID: installationID,
        providerID: providerID,
        projectID: projectID,
        catalogGeneration: catalogGeneration,
        refreshGeneration: refreshGeneration,
        previousMutation: previousMutation,
        forceRefresh: forceRefresh
      )
    }
  }

  private func performAgentModelCatalogRefresh(
    installationID: String,
    providerID: String,
    projectID: String?,
    catalogGeneration: UInt64,
    refreshGeneration: UInt64,
    previousMutation: Task<Void, Never>?,
    forceRefresh: Bool
  ) async {
    defer {
      if agentModelRefreshGeneration(for: providerID) == refreshGeneration {
        setAgentModelsRefreshing(false, providerID: providerID)
      }
    }

    do {
      await previousMutation?.value
      guard !Task.isCancelled,
        catalogGeneration == agentModelCatalogGeneration(for: providerID)
      else { return }
      let defaultRevision = agentModelDefaultRevision(for: providerID)
      let client = try currentClient()
      let persistedDefault = try await client.agentModelDefault(providerID: providerID)
      guard !Task.isCancelled,
        catalogGeneration == agentModelCatalogGeneration(for: providerID),
        refreshGeneration == agentModelRefreshGeneration(for: providerID),
        selectedProjectID == projectID,
        defaultRevision == agentModelDefaultRevision(for: providerID)
      else { return }
      let rawResponse = try await client.agentModels(
        installationID: installationID,
        projectID: projectID,
        modelID: nil,
        useStoredDefault: false,
        forceRefresh: forceRefresh
      )
      guard !Task.isCancelled,
        catalogGeneration == agentModelCatalogGeneration(for: providerID),
        refreshGeneration == agentModelRefreshGeneration(for: providerID),
        selectedProjectID == projectID,
        defaultRevision == agentModelDefaultRevision(for: providerID)
      else { return }

      let resolution = try await resolveAgentModelCatalog(
        client: client,
        installationID: installationID,
        projectID: projectID,
        providerID: providerID,
        persistedDefault: persistedDefault,
        catalogResponse: rawResponse
      )

      guard catalogGeneration == agentModelCatalogGeneration(for: providerID),
        refreshGeneration == agentModelRefreshGeneration(for: providerID),
        agentModelCatalogScopes[providerID]
          == AgentModelCatalogScope(
            installationID: installationID, projectID: projectID),
        selectedProjectID == projectID
      else { return }
      let correctedDefault = try await correctAgentModelDefaultIfNeeded(
        resolution: resolution,
        persistedDefault: persistedDefault,
        providerID: providerID,
        defaultRevision: defaultRevision,
        client: client
      )
      guard defaultRevision == agentModelDefaultRevision(for: providerID) else { return }

      guard !Task.isCancelled,
        catalogGeneration == agentModelCatalogGeneration(for: providerID),
        refreshGeneration == agentModelRefreshGeneration(for: providerID),
        selectedProjectID == projectID,
        defaultRevision == agentModelDefaultRevision(for: providerID)
      else { return }
      applyAgentModelCatalogRefresh(
        resolution: resolution,
        correctedDefault: correctedDefault,
        persistedDefault: persistedDefault,
        providerID: providerID,
        installationID: installationID,
        projectID: projectID
      )
    } catch {
      guard catalogGeneration == agentModelCatalogGeneration(for: providerID),
        refreshGeneration == agentModelRefreshGeneration(for: providerID)
      else { return }
      setAgentModelRefreshError(Self.message(error), providerID: providerID)
    }
  }

  private func resolveAgentModelCatalog(
    client: any BridgeServiceClientProtocol,
    installationID: String,
    projectID: String?,
    providerID: String,
    persistedDefault: IPCAgentModelDefaultResponse,
    catalogResponse: IPCAgentModelsResponse
  ) async throws -> AgentModelCatalogResolution {
    let defaultModel = persistedDefault.model
    let defaultWasRemoved = AgentModelCatalogResolver.defaultModelWasRemoved(
      defaultModel,
      from: catalogResponse
    )
    let response: IPCAgentModelsResponse
    if let defaultModel, !defaultWasRemoved,
      catalogResponse.models.first(where: { $0.modelID == defaultModel })?
        .reasoningCapabilitiesAvailable == false
    {
      response = try await client.agentModels(
        installationID: installationID,
        projectID: projectID,
        modelID: defaultModel,
        useStoredDefault: false
      )
    } else {
      response = catalogResponse
    }
    return AgentModelCatalogResolver.resolve(
      previousOptions: agentModelOptions(for: providerID),
      catalogResponse: catalogResponse,
      response: response,
      defaultModel: defaultModel,
      persistedEffort: persistedDefault.effort,
      defaultWasRemoved: defaultWasRemoved
    )
  }

  private func correctAgentModelDefaultIfNeeded(
    resolution: AgentModelCatalogResolution,
    persistedDefault: IPCAgentModelDefaultResponse,
    providerID: String,
    defaultRevision: UInt64,
    client: any BridgeServiceClientProtocol
  ) async throws -> IPCAgentModelDefaultResponse? {
    guard resolution.defaultWasRemoved || resolution.effortWasRemoved,
      defaultRevision == agentModelDefaultRevision(for: providerID)
    else { return nil }
    return try await client.setAgentDefaults(
      providerID: providerID,
      model: resolution.defaultWasRemoved ? nil : persistedDefault.model,
      permissionMode: persistedDefault.permissionMode,
      effort: nil
    )
  }

  private func applyAgentModelCatalogRefresh(
    resolution: AgentModelCatalogResolution,
    correctedDefault: IPCAgentModelDefaultResponse?,
    persistedDefault: IPCAgentModelDefaultResponse,
    providerID: String,
    installationID: String,
    projectID: String?
  ) {
    setAgentModelOptions(resolution.response.models, providerID: providerID)
    setAgentModelRefreshError(nil, providerID: providerID)
    let finalDefault = correctedDefault ?? persistedDefault
    if agentModelDefault(for: providerID).model != finalDefault.model {
      agentModelHydrationSuppressions[providerID] = AgentModelHydrationID(
        providerID: providerID,
        installationID: installationID,
        projectID: projectID,
        modelID: finalDefault.model
      )
    }
    if correctedDefault != nil {
      incrementAgentModelDefaultRevision(for: providerID)
    }
    applyAgentModelDefault(finalDefault, providerID: providerID)

    let message: String
    if resolution.addedCount == 0, resolution.removedCount == 0 {
      message =
        "\(agentProviderName(providerID)) 模型列表已是最新（共 \(resolution.response.models.count) 个）"
    } else {
      message =
        "\(agentProviderName(providerID)) 模型列表已刷新：新增 \(resolution.addedCount) 个，移除 \(resolution.removedCount) 个"
    }
    postToast(message, symbol: "arrow.clockwise", tone: .success)
  }

}
