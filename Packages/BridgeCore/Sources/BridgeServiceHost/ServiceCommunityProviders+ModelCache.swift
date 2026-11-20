import BridgeServiceCore
import Foundation

struct CommunityCachedModel: Codable, Equatable, Sendable {
  let model: ServiceGatewayModel
  let catalogID: String
  let npm: String
  let concurrency: Int

  init(_ route: CommunityModelRoute) {
    model = route.model
    catalogID = route.catalogID
    npm = route.npm
    concurrency = route.concurrency
  }

  var route: CommunityModelRoute {
    CommunityModelRoute(
      model: model, catalogID: catalogID, npm: npm, baseURL: "", concurrency: concurrency)
  }
}

private struct CommunityModelCache: Codable {
  let version: String
  let models: [CommunityCachedModel]
}

extension ServiceCommunityProviders {
  func loadModelCache(_ plugin: Plugin) async {
    guard loadedModelCaches.insert(plugin.id).inserted else { return }
    do {
      guard let value = try await store.setting(key: Self.cacheKey(plugin.id))?.value else {
        return
      }
      let cache = try JSONDecoder().decode(CommunityModelCache.self, from: Data(value.utf8))
      guard cache.version == plugin.version else { return }
      guard
        cache.models.allSatisfy({
          $0.model.pluginID == plugin.id && plugin.providers.contains($0.model.providerID)
        }), Set(cache.models.map(\.model.id)).count == cache.models.count
      else {
        throw ServiceCommunityProviderError.invalidStoredConfiguration
      }
      persistedRoutes[plugin.id] = cache.models
      for model in cache.models { routes[model.model.id] = model.route }
      if !cache.models.isEmpty { staleModels.insert(plugin.id) }
    } catch {
      runtimeErrors[plugin.id] = "模型目录缓存读取失败：\(error.localizedDescription)"
    }
  }

  func persistModelCache(_ plugin: Plugin, routes: [String: CommunityModelRoute]) async throws {
    let models = routes.values.map(CommunityCachedModel.init).sorted { $0.model.id < $1.model.id }
    guard persistedRoutes[plugin.id] != models else { return }
    let data = try JSONEncoder().encode(
      CommunityModelCache(version: plugin.version, models: models))
    let record = try ServiceSettingRecord(
      key: Self.cacheKey(plugin.id), value: String(decoding: data, as: UTF8.self), updatedAt: Date()
    )
    try await store.setSetting(record)
    persistedRoutes[plugin.id] = models
  }

  private static func cacheKey(_ id: String) -> String { "providers.community.models.\(id)" }
}
