#if os(Windows) || os(Linux)
  import BridgeIPC

  extension WindowsAgentDefaultsModel {
    func modelCatalogScope(
      providerID: String, installationID: String?, projectID: String?
    ) -> ModelCatalogScope {
      ModelCatalogScope(
        installationID: installationID, projectID: projectID,
        runtimeKey: providerID == "deepseek-harness-desktop" ? deepSeekDesktopModelScope : nil)
    }

    func refreshDeepSeekModelScope() async {
      let candidates = installations.filter { $0.providerID == "deepseek-harness-desktop" }
      guard let installation = candidates.first(where: { $0.isActive == true }) ?? candidates.first,
        let value = try? await client.manageDeepSeekHarnessDesktop(
          .init(installationID: installation.installationID))
      else { return }
      let scope = [installation.installationID, "native-desktop", value.desktop.profileID ?? ""]
        .joined(separator: "|")
      guard scope != deepSeekDesktopModelScope else { return }
      deepSeekDesktopModelScope = scope
      catalogScopes.removeValue(forKey: "deepseek-harness-desktop")
      modelCatalogs.removeValue(forKey: "deepseek-harness-desktop")
      modelRefreshGenerations["deepseek-harness-desktop", default: 0] &+= 1
      refreshingProviderIDs.remove("deepseek-harness-desktop")
    }
  }
#endif
