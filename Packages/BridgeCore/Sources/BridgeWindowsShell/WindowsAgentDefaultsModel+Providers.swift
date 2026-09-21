#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeServiceAppCore

  extension WindowsAgentDefaultsModel {
    func refreshAllProviderModels() async {
      for provider in providers {
        await refreshModels(
          providerID: provider.providerID,
          installationID: availableInstallation(for: provider.providerID)?.installationID,
          forceRefresh: false
        )
      }
    }

    func refreshModels(forceRefresh: Bool = true) async {
      guard let providerID = selectedProviderID else { return }
      await refreshModels(
        providerID: providerID,
        installationID: selectedInstallationID,
        forceRefresh: forceRefresh
      )
    }

    func refreshModels(
      providerID: String,
      installationID: String?,
      forceRefresh: Bool = false
    ) async {
      guard connectionState == .connected,
        let provider = providers.first(where: { $0.providerID == providerID }),
        !refreshingProviderIDs.contains(providerID)
      else { return }
      let installation = installationID.flatMap { requestedID in
        installations.first {
          $0.installationID == requestedID && $0.providerID == providerID
            && $0.isEnabled && $0.availability == "available"
        }
      }
      guard installationID == nil || installation != nil else { return }
      let hasCachedCatalog =
        !forceRefresh
        && cachedCatalog(providerID: providerID, installationID: installation?.installationID)
          != nil
      let locksModelSelection = forceRefresh || !hasCachedCatalog

      modelRefreshGenerations[providerID, default: 0] &+= 1
      let generation = modelRefreshGenerations[providerID, default: 0]
      if locksModelSelection {
        refreshingProviderIDs.insert(providerID)
      }
      providerErrors[providerID] = nil
      if locksModelSelection {
        statusText = "正在读取 \(provider.displayName) 模型…"
        publishDisplay()
      }
      defer {
        if locksModelSelection, modelRefreshGenerations[providerID] == generation {
          refreshingProviderIDs.remove(providerID)
          publishDisplay()
        }
      }

      do {
        let status = try await client.status()
        workbenchProjectID = status.workbenchProjectID
        let persistedDefault = try await client.agentModelDefault(providerID: providerID)
        guard modelRefreshGenerations[providerID] == generation else { return }
        let catalogResponse: IPCAgentModelsResponse
        if hasCachedCatalog,
          let cached = cachedCatalog(
            providerID: providerID,
            installationID: installation?.installationID
          )
        {
          catalogResponse = IPCAgentModelsResponse(models: cached)
        } else {
          catalogResponse = try await loadModels(
            provider: provider,
            installation: installation,
            modelID: nil,
            forceRefresh: forceRefresh
          )
        }
        guard modelRefreshGenerations[providerID] == generation else { return }
        let defaultWasRemoved = AgentModelCatalogResolver.defaultModelWasRemoved(
          persistedDefault.model,
          from: catalogResponse
        )
        let response = try await modelSpecificResponse(
          provider: provider,
          installation: installation,
          persistedDefault: persistedDefault,
          catalogResponse: catalogResponse,
          defaultWasRemoved: defaultWasRemoved
        )
        guard modelRefreshGenerations[providerID] == generation else { return }
        let resolution = AgentModelCatalogResolver.resolve(
          previousOptions: modelCatalogs[providerID] ?? [],
          catalogResponse: catalogResponse,
          response: response,
          defaultModel: persistedDefault.model,
          persistedEffort: persistedDefault.effort,
          defaultWasRemoved: defaultWasRemoved
        )
        let finalDefault = try await correctDefaultIfNeeded(
          providerID: providerID,
          persistedDefault: persistedDefault,
          resolution: resolution
        )
        guard modelRefreshGenerations[providerID] == generation else { return }

        persistedDefaults[providerID] = finalDefault
        modelCatalogs[providerID] = resolution.response.models
        applySelectedProvider(
          providerID: providerID,
          installation: installation,
          defaults: finalDefault,
          catalog: resolution.response.models
        )
        catalogInstallationIDs[providerID] = installation?.installationID ?? ""
        providerErrors[providerID] = nil
        if resolution.addedCount == 0, resolution.removedCount == 0 {
          statusText = "已加载 \(provider.displayName) 的 \(resolution.response.models.count) 个模型。"
        } else {
          statusText =
            "\(provider.displayName) 模型已刷新：新增 \(resolution.addedCount) 个，移除 \(resolution.removedCount) 个。"
        }
        if !locksModelSelection {
          publishDisplay()
        }
      } catch {
        guard modelRefreshGenerations[providerID] == generation else { return }
        let message = BridgeServiceErrorMessage.message(error)
        providerErrors[providerID] = "Agent 模型读取失败：\(message)"
        statusText = providerErrors[providerID]!
        publishDisplay()
      }
    }

    private func modelSpecificResponse(
      provider: IPCAgentProviderSummary,
      installation: IPCAgentInstallationSummary?,
      persistedDefault: IPCAgentModelDefaultResponse,
      catalogResponse: IPCAgentModelsResponse,
      defaultWasRemoved: Bool
    ) async throws -> IPCAgentModelsResponse {
      guard !defaultWasRemoved,
        let modelID = persistedDefault.model,
        catalogResponse.models.first(where: { $0.modelID == modelID })?
          .reasoningCapabilitiesAvailable != true
      else { return catalogResponse }
      let detailed = try await loadModels(
        provider: provider,
        installation: installation,
        modelID: modelID,
        forceRefresh: false
      )
      return IPCAgentModelsResponse(
        models: mergedCatalog(catalogResponse.models, with: detailed.models)
      )
    }

    private func correctDefaultIfNeeded(
      providerID: String,
      persistedDefault: IPCAgentModelDefaultResponse,
      resolution: AgentModelCatalogResolution
    ) async throws -> IPCAgentModelDefaultResponse {
      guard resolution.defaultWasRemoved || resolution.effortWasRemoved else {
        return persistedDefault
      }
      return try await client.setAgentDefaults(
        providerID: providerID,
        model: resolution.defaultWasRemoved ? nil : persistedDefault.model,
        permissionMode: providerID == "opencode" ? persistedDefault.permissionMode : nil,
        effort: nil
      )
    }

    func loadModels(
      provider: IPCAgentProviderSummary,
      installation: IPCAgentInstallationSummary?,
      modelID: String?,
      forceRefresh: Bool = false
    ) async throws -> IPCAgentModelsResponse {
      guard provider.supportsModelSelection, let installation else {
        return IPCAgentModelsResponse(models: [])
      }
      return try await client.agentModels(
        installationID: installation.installationID,
        projectID: workbenchProjectID,
        modelID: modelID,
        useStoredDefault: false,
        forceRefresh: forceRefresh && modelID == nil
      )
    }

    func cachedCatalog(providerID: String, installationID: String?) -> [IPCAgentModelSummary]? {
      guard catalogInstallationIDs[providerID] == (installationID ?? "") else { return nil }
      return modelCatalogs[providerID]
    }

    func mergedCatalog(
      _ catalog: [IPCAgentModelSummary],
      with detailedModels: [IPCAgentModelSummary]
    ) -> [IPCAgentModelSummary] {
      guard !detailedModels.isEmpty else { return catalog }
      let detailsByID = Dictionary(uniqueKeysWithValues: detailedModels.map { ($0.modelID, $0) })
      return catalog.map { detailsByID[$0.modelID] ?? $0 }
        + detailedModels.filter { model in !catalog.contains(where: { $0.modelID == model.modelID })
        }
    }

    func applySelectedProvider(
      providerID: String,
      installation: IPCAgentInstallationSummary?,
      defaults: IPCAgentModelDefaultResponse,
      catalog: [IPCAgentModelSummary]
    ) {
      guard selectedProviderID == providerID else { return }
      let visibleDefaults = pendingDefaults[providerID] ?? defaults
      selectedInstallationID = installation?.installationID
      models = catalog
      selectedModelID = visibleDefaults.model
      selectedEffort = visibleDefaults.effort ?? ""
      let permissions = Self.permissionValues(for: providerID)
      selectedPermissionMode =
        permissions.contains(visibleDefaults.permissionMode)
        ? visibleDefaults.permissionMode : permissions[0]
    }

  }
#endif
