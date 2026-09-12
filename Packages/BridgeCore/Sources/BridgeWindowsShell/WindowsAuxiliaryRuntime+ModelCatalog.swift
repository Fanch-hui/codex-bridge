#if os(Windows)
  extension WindowsAuxiliaryRuntime {
    func refreshModels(model: WindowsWorkbenchModel) async {
      guard !settings.busy else { return }
      let catalog = await settings.refreshModels(
        ensureService: {
          guard model.connectionState != .connected else { return }
          await model.startServiceAndConnect()
        },
        forceReconnect: {
          await model.startServiceAndConnect()
        }
      )
      if let catalog {
        model.applyModelCatalog(catalog)
      } else if let error = settings.modelError {
        model.applyModelCatalogError(error)
      }
    }
  }
#endif
