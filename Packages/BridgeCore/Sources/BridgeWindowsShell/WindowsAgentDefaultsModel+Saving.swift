#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeServiceAppCore

  extension WindowsAgentDefaultsModel {
    func saveDefaults(model: String, permissionMode: String, effort: String) async {
      guard let providerID = selectedProviderID else {
        statusText = "请选择 Agent Provider。"
        feedback.postAlert(statusText, title: "Agent 默认设置无法保存")
        publishDisplay()
        return
      }
      await saveDefaults(
        providerID: providerID,
        installationID: selectedInstallationID,
        model: model,
        permissionMode: permissionMode,
        effort: effort
      )
    }

    func saveDefaults(
      providerID: String,
      installationID: String?,
      model: String?,
      permissionMode: String,
      effort: String
    ) async {
      guard connectionState == .connected,
        !refreshingProviderIDs.contains(providerID),
        let provider = providers.first(where: { $0.providerID == providerID }),
        Self.permissionValues(for: providerID).contains(permissionMode)
      else { return }
      let installation = installationID.flatMap { requestedID in
        installations.first {
          $0.installationID == requestedID && $0.providerID == providerID
            && $0.isEnabled && $0.availability == "available"
        }
      }
      guard installationID == nil || installation != nil else { return }

      let normalizedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
      let requestedModel = normalizedModel.flatMap { $0.isEmpty ? nil : $0 }
      guard
        isValidSelection(
          provider: provider,
          providerID: providerID,
          modelID: requestedModel,
          effort: effort
        )
      else { return }

      saveGenerations[providerID, default: 0] &+= 1
      let generation = saveGenerations[providerID, default: 0]
      let optimistic = IPCAgentModelDefaultResponse(
        providerID: providerID,
        model: requestedModel,
        permissionMode: permissionMode,
        effort: effort.isEmpty ? nil : effort
      )
      pendingDefaults[providerID] = optimistic
      applyOptimisticSelection(
        providerID: providerID,
        installationID: installation?.installationID,
        defaults: optimistic
      )
      providerErrors[providerID] = nil
      publishDisplay()

      let previous = saveTasks[providerID]
      let operation = Task { [weak self] in
        await previous?.value
        guard !Task.isCancelled else { return }
        await self?.performSave(
          providerID: providerID,
          installation: installation,
          defaults: optimistic,
          generation: generation
        )
      }
      saveTasks[providerID] = operation
      await operation.value
      if saveGenerations[providerID] == generation {
        saveTasks.removeValue(forKey: providerID)
      }
    }

    private func performSave(
      providerID: String,
      installation: IPCAgentInstallationSummary?,
      defaults: IPCAgentModelDefaultResponse,
      generation: UInt64
    ) async {
      guard isCurrentSave(providerID: providerID, generation: generation) else { return }
      savingProviderIDs.insert(providerID)
      statusText = "正在保存 Agent 默认设置…"
      publishDisplay()
      defer {
        if isCurrentSave(providerID: providerID, generation: generation) {
          savingProviderIDs.remove(providerID)
          publishDisplay()
        }
      }

      do {
        let persisted = try await client.setAgentDefaults(
          providerID: providerID,
          model: defaults.model,
          permissionMode: defaults.permissionMode,
          effort: defaults.effort
        )
        let catalog = try await catalogAfterSave(
          providerID: providerID,
          provider: providers.first(where: { $0.providerID == providerID }),
          installation: installation,
          persistedDefault: persisted
        )
        guard isCurrentSave(providerID: providerID, generation: generation) else { return }
        persistedDefaults[providerID] = persisted
        pendingDefaults.removeValue(forKey: providerID)
        modelCatalogs[providerID] = catalog
        catalogInstallationIDs[providerID] = installation?.installationID ?? ""
        providerErrors[providerID] = nil
        applySelectedProvider(
          providerID: providerID,
          installation: installation,
          defaults: persisted,
          catalog: catalog
        )
        statusText = "\(providerName(providerID)) 默认设置已保存。"
        feedback.postToast(statusText)
      } catch {
        guard isCurrentSave(providerID: providerID, generation: generation) else { return }
        pendingDefaults.removeValue(forKey: providerID)
        statusText = "Agent 默认设置保存失败：\(BridgeServiceErrorMessage.message(error))"
        providerErrors[providerID] = statusText
        feedback.postAlert(statusText)
      }
    }

    private func catalogAfterSave(
      providerID: String,
      provider: IPCAgentProviderSummary?,
      installation: IPCAgentInstallationSummary?,
      persistedDefault: IPCAgentModelDefaultResponse
    ) async throws -> [IPCAgentModelSummary] {
      let catalog = modelCatalogs[providerID] ?? []
      guard let provider, provider.supportsModelSelection else { return catalog }
      guard let modelID = persistedDefault.model,
        catalog.first(where: { $0.modelID == modelID })?
          .reasoningCapabilitiesAvailable != true
      else { return catalog }
      let detailed = try await loadModels(
        provider: provider,
        installation: installation,
        modelID: modelID
      )
      return mergedCatalog(catalog, with: detailed.models)
    }

    private func isValidSelection(
      provider: IPCAgentProviderSummary,
      providerID: String,
      modelID: String?,
      effort: String
    ) -> Bool {
      let catalog = modelCatalogs[providerID] ?? []
      if let modelID {
        guard provider.supportsModelSelection,
          catalog.contains(where: { $0.modelID == modelID })
        else { return false }
      }
      guard !effort.isEmpty else { return true }
      let summary = AgentModelCatalogResolver.modelForSelection(
        modelID: modelID,
        models: catalog
      )
      guard provider.supportsEffortSelection,
        summary?.reasoningCapabilitiesAvailable == true
      else { return false }
      return summary?.supportedReasoningEfforts.contains(effort) == true
    }

    private func applyOptimisticSelection(
      providerID: String,
      installationID: String?,
      defaults: IPCAgentModelDefaultResponse
    ) {
      guard selectedProviderID == providerID else { return }
      selectedInstallationID = installationID
      selectedModelID = defaults.model
      selectedEffort = defaults.effort ?? ""
      let permissions = Self.permissionValues(for: providerID)
      selectedPermissionMode =
        permissions.contains(defaults.permissionMode)
        ? defaults.permissionMode : permissions[0]
    }

    private func isCurrentSave(providerID: String, generation: UInt64) -> Bool {
      saveGenerations[providerID] == generation
    }

    private func providerName(_ providerID: String) -> String {
      providers.first(where: { $0.providerID == providerID })?.displayName ?? providerID
    }
  }
#endif
