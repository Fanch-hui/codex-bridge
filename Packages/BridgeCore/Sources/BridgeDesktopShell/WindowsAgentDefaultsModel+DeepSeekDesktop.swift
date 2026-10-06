#if os(Windows) || os(Linux)
  import BridgeIPC

  extension WindowsAgentDefaultsModel {
    func refreshDeepSeekModelScope() async {
      let candidates = installations.filter { $0.providerID == "deepseek-harness" }
      guard let installation = candidates.first(where: { $0.isActive == true }) ?? candidates.first,
        let value = try? await client.manageDeepSeekHarnessDesktop(
          .init(installationID: installation.installationID))
      else { return }
      let scope = [installation.installationID, value.mode.rawValue, value.desktop.profileID ?? ""]
        .joined(separator: "|")
      guard scope != deepSeekDesktopModelScope else { return }
      deepSeekDesktopModelScope = scope
      catalogScopes.removeValue(forKey: "deepseek-harness")
      modelCatalogs.removeValue(forKey: "deepseek-harness")
      modelRefreshGenerations["deepseek-harness", default: 0] &+= 1
      refreshingProviderIDs.remove("deepseek-harness")
    }
  }
#endif
