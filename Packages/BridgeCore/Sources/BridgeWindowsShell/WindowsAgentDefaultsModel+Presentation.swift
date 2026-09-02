#if os(Windows)
  import BridgeDesktopUI
  import BridgeIPC

  extension WindowsAgentDefaultsModel {
    func providerDefaultItems() -> [BridgeDesktopAgentDefaultState] {
      providers.map { provider in
        let installation = availableInstallation(for: provider.providerID)
        let defaults = persistedDefaults[provider.providerID]
        let catalog = modelCatalogs[provider.providerID] ?? []
        let selectedModel = defaults?.model.flatMap { modelID in
          catalog.first(where: { $0.modelID == modelID })
        }
        let efforts = DirectWorkspacePresentation.effortValues(
          catalog: selectedModel?.supportedReasoningEfforts
            ?? catalog.flatMap(\.supportedReasoningEfforts),
          selected: [defaults?.effort ?? ""],
          includesProviderDefault: true
        )
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
          permissionOptions: Self.permissionValues(for: provider.providerID).map {
            Self.permissionChoice($0)
          },
          canSave: connectionState == .connected && !busy && installation != nil,
          canRefreshModels: provider.supportsModelSelection
            && installation?.effectiveCapabilities.contains("selection.model") == true,
          isRefreshingModels: refreshingProviderIDs.contains(provider.providerID),
          errorMessage: providerErrors[provider.providerID]
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
      let title: String
      switch value {
      case "": title = "Provider 默认"
      case "none": title = "无"
      case "minimal": title = "最低"
      case "low": title = "低"
      case "medium": title = "中"
      case "high": title = "高"
      case "xhigh", "extra_high": title = "极高"
      case "max": title = "最高"
      case "ultra": title = "Ultra"
      default: title = value
      }
      return BridgeDesktopChoice(id: value, title: title)
    }

    private static func permissionChoice(_ value: String) -> BridgeDesktopChoice {
      let title: String
      switch value {
      case "build": title = "工作区可写（Build）"
      case "plan": title = "只读（Plan）"
      case "workspace-write": title = "工作区可写"
      case "read-only": title = "只读"
      default: title = value
      }
      return BridgeDesktopChoice(id: value, title: title)
    }
  }
#endif
