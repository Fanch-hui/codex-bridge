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
      refreshingProviderIDs.insert(providerID)
      providerErrors[providerID] = nil
      statusText = "正在读取 \(provider.displayName) 模型…"
      publishDisplay()
      defer {
        refreshingProviderIDs.remove(providerID)
        publishDisplay()
      }
      do {
        let defaults = try await client.agentModelDefault(providerID: providerID)
        let catalog = try await loadModels(provider: provider, installation: installation)
        persistedDefaults[providerID] = defaults
        modelCatalogs[providerID] = catalog
        applySelectedProvider(
          providerID: providerID,
          installation: installation,
          defaults: defaults,
          catalog: catalog
        )
        statusText = "已加载 \(provider.displayName) 的 \(catalog.count) 个模型。"
      } catch {
        let message = BridgeServiceErrorMessage.message(error)
        providerErrors[providerID] = "Agent 模型读取失败：\(message)"
        statusText = providerErrors[providerID]!
      }
    }

    func saveDefaults(model: String, permissionMode: String, effort: String) async {
      guard let providerID = selectedProviderID, let installationID = selectedInstallationID else {
        statusText = "请选择可用的 Agent 安装。"
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
        let provider = providers.first(where: { $0.providerID == providerID }),
        let installation = installations.first(where: {
          $0.installationID == installationID && $0.providerID == providerID
            && $0.isEnabled && $0.availability == "available"
        }), Self.permissionValues(for: providerID).contains(permissionMode)
      else { return }
      let normalizedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
      let requestedModel = normalizedModel?.isEmpty == true ? nil : normalizedModel
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
        persistedDefaults[providerID] = persisted
        providerErrors[providerID] = nil
        applySelectedProvider(
          providerID: providerID,
          installation: installation,
          defaults: persisted,
          catalog: modelCatalogs[providerID] ?? []
        )
        statusText = "\(providerName(providerID)) 默认设置已保存。"
      } catch {
        statusText = "Agent 默认设置保存失败：\(BridgeServiceErrorMessage.message(error))"
        providerErrors[providerID] = statusText
      }
    }

    private func loadModels(
      provider: IPCAgentProviderSummary,
      installation: IPCAgentInstallationSummary?
    ) async throws -> [IPCAgentModelSummary] {
      guard provider.supportsModelSelection, let installation else { return [] }
      return try await client.agentModels(
        installationID: installation.installationID,
        projectID: nil,
        modelID: nil,
        useStoredDefault: false
      ).models
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
