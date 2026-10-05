import BridgeIPC
import BridgeServiceAppCore

extension BridgeServiceAppModel {
  func saveAgentModelDefault(_ model: String?, providerID: String = "opencode") {
    incrementAgentModelCatalogGeneration(for: providerID)
    agentModelHydrationSuppressions.removeValue(forKey: providerID)
    let current = agentModelDefault(for: providerID)
    saveAgentDefaults(
      providerID: providerID,
      model: model,
      permissionMode: current.permissionMode,
      effort: nil
    )
  }

  func saveOpenCodePermissionMode(_ mode: String) {
    saveAgentPermissionMode(mode, providerID: "opencode")
  }

  func saveAgentPermissionMode(_ mode: String, providerID: String) {
    let current = agentModelDefault(for: providerID)
    saveAgentDefaults(
      providerID: providerID,
      model: current.model,
      permissionMode: mode,
      effort: current.effort
    )
  }

  func saveAgentEffort(_ effort: String?, providerID: String = "opencode") {
    let current = agentModelDefault(for: providerID)
    saveAgentDefaults(
      providerID: providerID,
      model: current.model,
      permissionMode: current.permissionMode,
      effort: effort
    )
  }

  func saveAgentDefaults(
    providerID: String,
    model: String?,
    permissionMode: String?,
    effort: String?
  ) {
    let previous = agentModelDefault(for: providerID)
    incrementAgentModelDefaultRevision(for: providerID)
    let revision = agentModelDefaultRevision(for: providerID)
    applyAgentModelDefault(
      IPCAgentModelDefaultResponse(
        providerID: providerID,
        model: model,
        permissionMode: permissionMode ?? previous.permissionMode,
        effort: effort
      ),
      providerID: providerID
    )
    let previousMutation = agentModelDefaultMutationTasks[providerID]
    let task = Task { [weak self, previousMutation] in
      await previousMutation?.value
      guard let self, !Task.isCancelled else { return }
      defer {
        if self.agentModelDefaultRevision(for: providerID) == revision {
          self.agentModelDefaultMutationTasks.removeValue(forKey: providerID)
        }
      }
      do {
        let client = try self.currentClient()
        let persisted = try await client.setAgentDefaults(
          providerID: providerID,
          model: model,
          permissionMode: permissionMode,
          effort: effort
        )
        guard self.agentModelDefaultRevision(for: providerID) == revision else { return }
        self.applyAgentModelDefault(persisted, providerID: providerID)
        self.postToast(
          "\(self.agentProviderName(providerID)) 默认设置已保存",
          symbol: "checkmark.circle.fill",
          tone: .success
        )
      } catch {
        guard self.agentModelDefaultRevision(for: providerID) == revision else { return }
        self.applyAgentModelDefault(previous, providerID: providerID)
        self.errorMessage = Self.message(error)
      }
    }
    agentModelDefaultMutationTasks[providerID] = task
  }

  func agentProviderName(_ providerID: String) -> String {
    agentProviders.first(where: { $0.providerID == providerID })?.displayName ?? providerID
  }

  func applyAgentModelDefault(
    _ value: IPCAgentModelDefaultResponse,
    providerID: String
  ) {
    agentModelDefaults[providerID] = value
    guard providerID == "opencode" else { return }
    openCodeDefaultModel = value.model
    openCodeDefaultPermissionMode = value.permissionMode
    openCodeDefaultEffort = value.effort
  }

  func incrementAgentModelCatalogGeneration(for providerID: String) {
    agentModelCatalogGenerations[providerID, default: 0] &+= 1
  }
  func agentModelCatalogGeneration(for providerID: String) -> UInt64 {
    agentModelCatalogGenerations[providerID, default: 0]
  }
  func incrementAgentModelRefreshGeneration(for providerID: String) {
    agentModelRefreshGenerations[providerID, default: 0] &+= 1
  }
  func agentModelRefreshGeneration(for providerID: String) -> UInt64 {
    agentModelRefreshGenerations[providerID, default: 0]
  }
  func incrementAgentModelDefaultLoadGeneration(for providerID: String) {
    agentModelDefaultLoadGenerations[providerID, default: 0] &+= 1
  }
  func agentModelDefaultLoadGeneration(for providerID: String) -> UInt64 {
    agentModelDefaultLoadGenerations[providerID, default: 0]
  }
  func incrementAgentModelDefaultRevision(for providerID: String) {
    agentModelDefaultRevisions[providerID, default: 0] &+= 1
  }
  func agentModelDefaultRevision(for providerID: String) -> UInt64 {
    agentModelDefaultRevisions[providerID, default: 0]
  }

  func setAgentModelOptions(
    _ options: [IPCAgentModelSummary],
    providerID: String
  ) {
    if providerID == "opencode" {
      agentModelOptions = options
    } else {
      agentModelOptionsByProvider[providerID] = options
    }
  }

  func setAgentModelsRefreshing(_ refreshing: Bool, providerID: String) {
    if refreshing {
      agentModelRefreshingProviders.insert(providerID)
    } else {
      agentModelRefreshingProviders.remove(providerID)
    }
    if providerID == "opencode" {
      isRefreshingAgentModels = refreshing
    }
  }

  func setAgentModelsHydrating(_ hydrating: Bool, providerID: String) {
    if hydrating {
      agentModelHydratingProviders.insert(providerID)
    } else {
      agentModelHydrationGenerations.removeValue(forKey: providerID)
      agentModelHydratingProviders.remove(providerID)
    }
  }

  func setAgentModelRefreshError(_ error: String?, providerID: String) {
    if let error {
      agentModelRefreshErrorsByProvider[providerID] = error
    } else {
      agentModelRefreshErrorsByProvider.removeValue(forKey: providerID)
    }
    if providerID == "opencode" {
      agentModelRefreshError = error
    }
  }
}
