#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeServiceAppCore

  extension WindowsAgentDefaultsModel {
    func refreshAllProviderModels() async {
      for provider in providers {
        await refreshModels(
          providerID: provider.providerID,
          installationID: availableInstallation(for: provider.providerID)?.installationID
        )
      }
    }

    func refreshModels() async {
      guard let providerID = selectedProviderID else { return }
      await refreshModels(providerID: providerID, installationID: selectedInstallationID)
    }

    func refreshModels(providerID: String, installationID: String?) async {
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

      modelRefreshGenerations[providerID, default: 0] &+= 1
      let generation = modelRefreshGenerations[providerID, default: 0]
      refreshingProviderIDs.insert(providerID)
      providerErrors[providerID] = nil
      statusText = "正在读取 \(provider.displayName) 模型…"
      publishDisplay()
      defer {
        if modelRefreshGenerations[providerID] == generation {
          refreshingProviderIDs.remove(providerID)
          publishDisplay()
        }
      }

      do {
        let status = try await client.status()
        workbenchProjectID = status.workbenchProjectID
        let persistedDefault = try await client.agentModelDefault(providerID: providerID)
        guard modelRefreshGenerations[providerID] == generation else { return }
        let catalogResponse = try await loadModels(
          provider: provider,
          installation: installation,
          modelID: nil
        )
        guard modelRefreshGenerations[providerID] == generation else { return }
        let defaultWasRemoved = AgentModelCatalogResolver.defaultModelWasRemoved(
          persistedDefault.model,
          from: catalogResponse
        )
        let response = try await modelSpecificResponse(
          providerID: providerID,
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
        providerErrors[providerID] = nil
        if resolution.addedCount == 0, resolution.removedCount == 0 {
          statusText = "已加载 \(provider.displayName) 的 \(resolution.response.models.count) 个模型。"
        } else {
          statusText =
            "\(provider.displayName) 模型已刷新：新增 \(resolution.addedCount) 个，移除 \(resolution.removedCount) 个。"
        }
      } catch {
        guard modelRefreshGenerations[providerID] == generation else { return }
        let message = BridgeServiceErrorMessage.message(error)
        providerErrors[providerID] = "Agent 模型读取失败：\(message)"
        statusText = providerErrors[providerID]!
      }
    }

    func saveDefaults(model: String, permissionMode: String, effort: String) async {
      guard let providerID = selectedProviderID, let installationID = selectedInstallationID else {
        statusText = "请选择可用的 Agent 安装。"
        feedback.postAlert(statusText, title: "Agent 默认设置无法保存")
        publishDisplay()
        return
      }
      await saveDefaults(
        providerID: providerID,
        installationID: installationID,
        model: model,
        permissionMode: permissionMode,
        effort: effort
      )
    }

    func saveDefaults(
      providerID: String,
      installationID: String,
      model: String?,
      permissionMode: String,
      effort: String
    ) async {
      guard connectionState == .connected, !busy,
        !refreshingProviderIDs.contains(providerID),
        let provider = providers.first(where: { $0.providerID == providerID }),
        let installation = installations.first(where: {
          $0.installationID == installationID && $0.providerID == providerID
            && $0.isEnabled && $0.availability == "available"
        }), Self.permissionValues(for: providerID).contains(permissionMode)
      else { return }
      let normalizedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
      let requestedModel = normalizedModel.flatMap { $0.isEmpty ? nil : $0 }
      let catalog = modelCatalogs[providerID] ?? []
      if let requestedModel {
        guard provider.supportsModelSelection,
          catalog.contains(where: { $0.modelID == requestedModel })
        else { return }
      }
      if !effort.isEmpty {
        let effectiveModel = requestedModel ?? persistedDefaults[providerID]?.model
        guard provider.supportsEffortSelection,
          catalog.first(where: { $0.modelID == effectiveModel })?
            .supportedReasoningEfforts.contains(effort) == true
        else { return }
      }
      modelRefreshGenerations[providerID, default: 0] &+= 1
      busy = true
      statusText = "正在保存 Agent 默认设置…"
      publishDisplay()
      defer {
        busy = false
        publishDisplay()
      }
      do {
        let persisted = try await client.setAgentDefaults(
          providerID: providerID,
          model: requestedModel,
          permissionMode: permissionMode,
          effort: effort.isEmpty ? nil : effort
        )
        let refreshedCatalog = await refreshedCatalogAfterSave(
          providerID: providerID,
          provider: provider,
          installation: installation,
          persistedDefault: persisted,
          fallback: catalog
        )
        persistedDefaults[providerID] = persisted
        modelCatalogs[providerID] = refreshedCatalog
        providerErrors[providerID] = nil
        applySelectedProvider(
          providerID: providerID,
          installation: installation,
          defaults: persisted,
          catalog: refreshedCatalog
        )
        statusText = "\(providerName(providerID)) 默认设置已保存。"
        feedback.postToast(statusText)
      } catch {
        statusText = "Agent 默认设置保存失败：\(BridgeServiceErrorMessage.message(error))"
        providerErrors[providerID] = statusText
        feedback.postAlert(statusText)
      }
    }

    private func refreshedCatalogAfterSave(
      providerID: String,
      provider: IPCAgentProviderSummary,
      installation: IPCAgentInstallationSummary,
      persistedDefault: IPCAgentModelDefaultResponse,
      fallback: [IPCAgentModelSummary]
    ) async -> [IPCAgentModelSummary] {
      guard provider.supportsModelSelection else { return [] }
      do {
        let catalog = try await loadModels(
          provider: provider,
          installation: installation,
          modelID: nil
        )
        guard providerID != "deepseek-harness", let modelID = persistedDefault.model else {
          return catalog.models
        }
        return try await loadModels(
          provider: provider,
          installation: installation,
          modelID: modelID
        ).models
      } catch {
        return fallback
      }
    }

    private func modelSpecificResponse(
      providerID: String,
      provider: IPCAgentProviderSummary,
      installation: IPCAgentInstallationSummary?,
      persistedDefault: IPCAgentModelDefaultResponse,
      catalogResponse: IPCAgentModelsResponse,
      defaultWasRemoved: Bool
    ) async throws -> IPCAgentModelsResponse {
      guard providerID != "deepseek-harness", !defaultWasRemoved,
        let modelID = persistedDefault.model
      else { return catalogResponse }
      return try await loadModels(
        provider: provider,
        installation: installation,
        modelID: modelID
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

    private func loadModels(
      provider: IPCAgentProviderSummary,
      installation: IPCAgentInstallationSummary?,
      modelID: String?
    ) async throws -> IPCAgentModelsResponse {
      guard provider.supportsModelSelection, let installation else {
        return IPCAgentModelsResponse(models: [])
      }
      return try await client.agentModels(
        installationID: installation.installationID,
        projectID: workbenchProjectID,
        modelID: modelID,
        useStoredDefault: false
      )
    }

    private func applySelectedProvider(
      providerID: String,
      installation: IPCAgentInstallationSummary?,
      defaults: IPCAgentModelDefaultResponse,
      catalog: [IPCAgentModelSummary]
    ) {
      guard selectedProviderID == providerID else { return }
      selectedInstallationID = installation?.installationID
      models = catalog
      selectedModelID = defaults.model
      selectedEffort = defaults.effort ?? ""
      let permissions = Self.permissionValues(for: providerID)
      selectedPermissionMode =
        permissions.contains(defaults.permissionMode)
        ? defaults.permissionMode : permissions[0]
    }

    private func providerName(_ providerID: String) -> String {
      providers.first(where: { $0.providerID == providerID })?.displayName ?? providerID
    }
  }
#endif
