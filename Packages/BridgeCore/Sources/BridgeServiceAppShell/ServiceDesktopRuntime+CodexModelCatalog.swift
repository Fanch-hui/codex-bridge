import BridgeIPC
import BridgeServiceAppCore

struct CodexModelCatalogRequestState {
  private(set) var catalogGeneration: UInt64 = 0
  private(set) var connectionGeneration: UInt64 = 0
  private(set) var preferenceGeneration: UInt64 = 0
  private(set) var isSavingPreferences = false

  mutating func beginCatalog() -> UInt64 {
    catalogGeneration += 1
    return catalogGeneration
  }

  mutating func beginPreferenceMutation() -> UInt64 {
    catalogGeneration += 1
    preferenceGeneration += 1
    isSavingPreferences = true
    return preferenceGeneration
  }

  mutating func finishPreferenceMutation(_ generation: UInt64) -> Bool {
    guard preferenceGeneration == generation else { return false }
    catalogGeneration += 1
    isSavingPreferences = false
    return true
  }

  mutating func invalidate() {
    catalogGeneration += 1
    connectionGeneration += 1
    preferenceGeneration += 1
    isSavingPreferences = false
  }
}

extension BridgeServiceAppModel {
  func refreshCodexModels() async {
    guard !stopped, !isRefreshingModels else { return }
    isRefreshingModels = true
    modelCatalogError = nil
    defer { isRefreshingModels = false }

    do {
      _ = try await currentClient().status()
    } catch {
      await connect(includeCatalog: false, includeCollections: false)
    }
    guard !stopped else { return }
    do {
      let client = try currentClient()
      await refreshModelCatalog(client: client, forceRefresh: true, includeInstructions: false)
    } catch {
      modelCatalogError = errorMessage ?? Self.message(error)
    }
  }

  func refreshModelCatalog(
    client: any BridgeServiceClientProtocol,
    forceRefresh: Bool,
    includeInstructions: Bool = true
  ) async {
    let generation = codexModelCatalogRequests.beginCatalog()
    do {
      let catalog = try await client.modelCatalog(forceRefresh: forceRefresh)
      guard generation == codexModelCatalogRequests.catalogGeneration else { return }
      models = catalog.models
      if !codexModelCatalogRequests.isSavingPreferences {
        modelPreferences = catalog.preferences
      }
      modelCatalogError = nil
    } catch {
      guard generation == codexModelCatalogRequests.catalogGeneration else { return }
      modelCatalogError = Self.message(error)
    }
    if includeInstructions, let instructions = try? await client.customInstructions(),
      generation == codexModelCatalogRequests.catalogGeneration
    {
      customInstructions = instructions
    }
  }

  func setModelPreferences(_ preferences: IPCModelPreferences) {
    let generation = codexModelCatalogRequests.beginPreferenceMutation()
    errorMessage = nil
    Task { [weak self] in
      guard let self else { return }
      guard self.codexModelCatalogRequests.preferenceGeneration == generation else { return }
      do {
        try await self.currentClient().setModelPreferences(preferences)
        guard self.codexModelCatalogRequests.finishPreferenceMutation(generation) else { return }
        self.modelPreferences = preferences
        await self.refreshModelCatalog(
          client: try self.currentClient(), forceRefresh: false, includeInstructions: false)
        self.postToast("模型偏好设置已更新")
      } catch {
        guard self.codexModelCatalogRequests.finishPreferenceMutation(generation) else { return }
        self.errorMessage = Self.message(error)
      }
    }
  }
}
