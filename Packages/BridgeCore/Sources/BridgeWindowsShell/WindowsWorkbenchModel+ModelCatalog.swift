#if os(Windows)
  import BridgeIPC

  extension WindowsWorkbenchModel {
    func applyModelCatalog(_ catalog: IPCModelCatalogResponse) {
      models = catalog.models
      modelPreferences = catalog.preferences
      modelError = nil
      refreshDisplaySnapshot()
    }

    func applyModelCatalogError(_ message: String?) {
      modelError = message
      refreshDisplaySnapshot()
    }
  }
#endif
