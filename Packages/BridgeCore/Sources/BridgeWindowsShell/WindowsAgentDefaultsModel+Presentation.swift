#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC
  import BridgeServiceAppCore

  extension WindowsAgentDefaultsModel {
    func providerDefaultItems() -> [BridgeDesktopAgentDefaultState] {
      providers.map { provider in
        let installation = availableInstallation(for: provider.providerID)
        let defaults = persistedDefaults[provider.providerID]
        let catalog = modelCatalogs[provider.providerID] ?? []
        let selectedModel: IPCAgentModelSummary?
        if let modelID = defaults?.model {
          selectedModel = catalog.first(where: { $0.modelID == modelID })
        } else {
          selectedModel =
            catalog.first(where: { !$0.supportedReasoningEfforts.isEmpty }) ?? catalog.first
        }
        let efforts = selectedModel?.supportedReasoningEfforts ?? []
        return BridgeDesktopAgentDefaultState(
          providerID: provider.providerID,
          providerName: provider.displayName,
          installationID: installation?.installationID,
          installationName: installation?.displayName,
          model: defaults?.model,
          modelOptions: catalog.map(WindowsDesktopAgentPresentation.model),
          effort: defaults?.effort,
          effortOptions: efforts.map(Self.effortChoice),
          permissionMode: permissionMode(defaults, providerID: provider.providerID),
          permissionOptions: BridgeDesktopPresentation.agentPermissionOptions(
            for: provider.providerID
          ),
          supportsWorkspaceWrite: installation.map {
            $0.effectiveCapabilities.contains("workspace.write_in_place")
              || $0.effectiveCapabilities.contains("workspace.write_isolated")
          } ?? true,
          canSave: connectionState == .connected && !busy,
          canRefreshModels: provider.supportsModelSelection
            && installation?.effectiveCapabilities.contains("selection.model") == true,
          isRefreshingModels: refreshingProviderIDs.contains(provider.providerID),
          errorMessage: providerErrors[provider.providerID],
          canSelectModel: provider.supportsModelSelection
            && installation?.effectiveCapabilities.contains("selection.model") == true,
          canSelectEffort: provider.supportsEffortSelection && installation != nil
            && selectedModel?.supportedReasoningEfforts.isEmpty == false
        )
      }
    }

    private func permissionMode(
      _ defaults: IPCAgentModelDefaultResponse?,
      providerID: String
    ) -> String {
      let values = Self.permissionValues(for: providerID)
      guard let mode = defaults?.permissionMode, values.contains(mode) else { return values[0] }
      return mode
    }

    private static func effortChoice(_ value: String) -> BridgeDesktopChoice {
      BridgeDesktopChoice(
        id: value,
        title: BridgeDesktopPresentation.extendedReasoningTitle(value)
      )
    }
  }
#endif
