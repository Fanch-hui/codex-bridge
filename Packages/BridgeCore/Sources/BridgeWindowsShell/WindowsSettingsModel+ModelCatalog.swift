#if os(Windows)
  import BridgeIPC
  import BridgeServiceAppCore
  import Foundation

  extension WindowsSettingsModel {
    func loadModelCatalog(forceRefresh: Bool) async -> IPCModelCatalogResponse? {
      do {
        let catalog = try await client.modelCatalog(forceRefresh: forceRefresh)
        models = catalog.models
        preferences = catalog.preferences
        modelError = nil
        return catalog
      } catch {
        modelError = BridgeServiceErrorMessage.message(error)
        return nil
      }
    }

    func refreshModels(
      ensureService: () async -> Void = {},
      forceReconnect: () async -> Void = {}
    ) async -> IPCModelCatalogResponse? {
      guard !busy else { return nil }
      busy = true
      isRefreshingModels = true
      modelError = nil
      statusText = "正在获取 Codex 模型…"
      publishDisplay()
      defer {
        busy = false
        isRefreshingModels = false
        publishDisplay()
      }

      if connectionState != .connected { await ensureService() }
      guard
        await confirmServiceConnection(
          forceReconnect: forceReconnect
        )
      else { return nil }

      guard let catalog = await loadModelCatalog(forceRefresh: true) else {
        statusText = "模型刷新失败：\(modelError ?? "无法读取模型目录")"
        feedback.postAlert(statusText)
        return nil
      }
      statusText = "Codex 模型已刷新，共 \(catalog.models.count) 个。"
      feedback.postToast(statusText)
      return catalog
    }

    private func confirmServiceConnection(forceReconnect: () async -> Void) async -> Bool {
      do {
        _ = try await client.status()
        connectionState = .connected
        return true
      } catch {
        connectionState = .unavailable
        await forceReconnect()
        do {
          _ = try await client.status()
          connectionState = .connected
          return true
        } catch {
          modelError = BridgeServiceErrorMessage.message(error)
          statusText = "模型刷新失败：\(modelError ?? "无法连接本机 Service")"
          feedback.postAlert(statusText)
          return false
        }
      }
    }
  }
#endif
