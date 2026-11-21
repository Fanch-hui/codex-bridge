import BridgeACP
import BridgeProviderRuntime
import BridgeSecurity
import Foundation

struct CommunityModelRoute: Codable, Equatable, Sendable {
  let model: ServiceGatewayModel
  let catalogID: String
  let npm: String
  let baseURL: String
  let concurrency: Int
}

extension ServiceCommunityProviders {
  func models() async throws -> [ServiceGatewayModel] {
    guard !shuttingDown else { throw ServiceCommunityProviderError.stopped }
    if let modelRefresh { return try await modelRefresh.value }
    try beginRequest()
    defer { endRequest() }
    let task = Task { try await self.refreshModels() }
    modelRefresh = task
    do {
      let result = try await task.value
      modelRefresh = nil
      return result
    } catch {
      modelRefresh = nil
      throw error
    }
  }

  func refreshModels() async throws -> [ServiceGatewayModel] {
    let enabled = try await records().filter { $0.isInstalled && $0.enabled }
    guard !enabled.isEmpty else {
      routes.removeAll()
      return []
    }
    for plugin in enabled { await loadModelCache(plugin) }
    let client: ProviderHostClient
    do { client = try await sharedHost() } catch {
      for plugin in enabled {
        staleModels.insert(plugin.id)
        runtimeErrors[plugin.id] = "社区供应商宿主不可用：\(error.localizedDescription)"
      }
      return routes.values.map(\.model).sorted { $0.id < $1.id }
    }
    var next = routes.filter { route in enabled.contains { $0.id == route.value.model.pluginID } }
    for plugin in enabled {
      var pluginRoutes: [String: CommunityModelRoute] = [:]
      var failures: [String] = []
      var stale = false
      if Self.supportsAutomaticPublicAccess(plugin) {
        do {
          try await connectAutomaticPublicAccess(plugin, using: client)
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          let detail = OutboundContentSecurity.redactedSecrets(
            error.localizedDescription, maximumUTF8Bytes: 1024)
          failures.append("公开访问连接失败：\(detail)")
        }
      }
      for provider in plugin.providers {
        do {
          let response = try await request(
            client, method: "providers", params: .object(["provider": .string(provider)]))
          guard let row = response.arrayValue?.first else {
            throw ServiceCommunityProviderError.pluginMissing
          }
          if row["fellBack"]?.boolValue == true {
            stale = true
            failures.append("\(provider)：模型目录暂不可用，保留上次结果。")
            pluginRoutes.merge(
              next.filter {
                $0.value.model.pluginID == plugin.id && $0.value.model.providerID == provider
              }
            ) { first, _ in first }
          } else {
            let (found, incompatible) = try Self.modelRoutes(
              row: row, plugin: plugin, provider: provider)
            pluginRoutes.merge(found) { first, _ in first }
            failures.append(contentsOf: incompatible)
          }
        } catch {
          stale = true
          failures.append("\(provider)：\(error.localizedDescription)")
          pluginRoutes.merge(
            next.filter {
              $0.value.model.pluginID == plugin.id && $0.value.model.providerID == provider
            }
          ) { first, _ in first }
        }
      }
      next = next.filter { $0.value.model.pluginID != plugin.id }
      next.merge(pluginRoutes) { first, _ in first }
      if stale { staleModels.insert(plugin.id) } else { staleModels.remove(plugin.id) }
      do { try await persistModelCache(plugin, routes: pluginRoutes) } catch {
        failures.append("模型目录缓存保存失败：\(error.localizedDescription)")
      }
      if failures.isEmpty {
        runtimeErrors.removeValue(forKey: plugin.id)
      } else {
        runtimeErrors[plugin.id] = failures.joined(separator: "；")
      }
    }
    routes = next
    return routes.values.map(\.model).sorted { $0.id < $1.id }
  }

  static func modelRoutes(row: ACPJSONValue, plugin: Plugin, provider: String) throws -> (
    [String: CommunityModelRoute], [String]
  ) {
    guard let accounts = row["accounts"]?.arrayValue, let models = row["models"]?.arrayValue else {
      throw ServiceCommunityProviderError.invalidRequest
    }
    var result: [String: CommunityModelRoute] = [:]
    var incompatible = Set<String>()
    for account in accounts {
      guard let key = account["key"]?.stringValue, !key.isEmpty else { continue }
      let available = account["models"]?.arrayValue.map { Set($0.compactMap(\.stringValue)) }
      for value in models {
        guard let catalogID = value["id"]?.stringValue, !catalogID.isEmpty,
          available?.contains(catalogID) ?? true
        else { continue }
        if value["decides"]?.boolValue == true { continue }
        if value["outputsSaid"]?.boolValue == true,
          !(value["outputs"]?.arrayValue?.contains(.string("text")) ?? false)
        {
          continue
        }
        let npm = value["npm"]?.stringValue.nonEmpty ?? row["npm"]?.stringValue ?? ""
        var base = value["url"]?.stringValue.nonEmpty ?? row["api"]?.stringValue ?? ""
        let protocolName: String
        do {
          protocolName = try Self.protocolName(npm)
          if plugin.package == "magpie-plugin-codar", plugin.version == "0.3.0",
            provider == "codar", protocolName == "chat",
            var address = URLComponents(string: base), address.host != nil,
            address.path.isEmpty || address.path == "/"
          {
            address.path = "/v1"
            base = address.string ?? base
          }
          if base.isEmpty && account["loaderBaseAvailable"]?.boolValue != true {
            throw ServiceCommunityProviderError.modelUnavailable
          }
          _ = try upstreamURL(base: base, protocolName: protocolName)
        } catch {
          incompatible.insert("\(provider)/\(catalogID)：\(error.localizedDescription)")
          continue
        }
        let apiID = value["apiId"]?.stringValue.nonEmpty ?? catalogID
        let identity = [plugin.id, provider, key, catalogID].map(encodedID).joined(separator: ".")
        let declared = row["maxConcurrency"]?.intValue ?? 0
        let model = ServiceGatewayModel(
          id: "community.\(identity)", name: value["name"]?.stringValue.nonEmpty ?? catalogID,
          providerID: provider, modelID: apiID, pluginID: plugin.id,
          protocolName: protocolName, account: key,
          maximumConcurrency: declared > 0 ? min(2, declared) : 2,
          contextWindow: value["context"]?.intValue.flatMap { $0 > 0 ? $0 : nil },
          defaultMaxTokens: value["output"]?.intValue.flatMap { $0 > 0 ? $0 : nil },
          supportsImages: value["inputsSaid"]?.boolValue == true
            ? value["inputs"]?.arrayValue?.contains(.string("image")) : nil,
          supportsSampling: value["temperature"]?.boolValue,
          providerName: row["name"]?.stringValue.nonEmpty,
          reasoningEfforts: ServiceGatewayModel.reasoningEfforts(
            (value["variants"]?.arrayValue ?? []).compactMap(\.stringValue)))
        result[model.id] = CommunityModelRoute(
          model: model, catalogID: catalogID, npm: npm, baseURL: base,
          concurrency: declared > 0 ? min(2, declared) : 2)
      }
    }
    return (result, incompatible.sorted())
  }

  func fetch(
    model: ServiceGatewayModel, body: Data, headers: [String: String] = [:], timeout: Duration,
    stream: @escaping ProviderHostClient.StreamHandler
  ) async throws {
    try beginRequest()
    defer { endRequest() }
    guard let route = routes[model.id], route.model == model,
      let pluginID = model.pluginID, let account = model.account,
      try await records().contains(where: { $0.id == pluginID && $0.isInstalled && $0.enabled })
    else { throw ServiceCommunityProviderError.modelUnavailable }
    let key = "\(pluginID)\u{0}\(model.providerID)\u{0}\(account)"
    guard accountRequests[key, default: 0] < route.concurrency else {
      throw ServiceCommunityProviderError.busy
    }
    accountRequests[key, default: 0] += 1
    defer {
      accountRequests[key, default: 1] -= 1
      if accountRequests[key] == 0 { accountRequests.removeValue(forKey: key) }
    }
    let client = try await sharedHost()
    let url = try Self.upstreamURL(base: route.baseURL, protocolName: model.protocolName)
    var upstreamHeaders = headers.mapValues(ACPJSONValue.string)
    upstreamHeaders["content-type"] = .string("application/json")
    _ = try await request(
      client, method: "fetch",
      params: .object([
        "provider": .string(model.providerID), "account": .string(account),
        "model": .string(route.catalogID), "npm": .string(route.npm),
        "url": .string(url), "method": .string("POST"),
        "headers": .object(upstreamHeaders),
        "body": .string(body.base64EncodedString()),
      ]), timeout: timeout, stream: stream)
  }

  static func protocolName(_ npm: String) throws -> String {
    switch npm {
    case "@ai-sdk/openai-compatible": "chat"
    case "@ai-sdk/openai": "responses"
    case "@ai-sdk/anthropic", "@ai-sdk/google-vertex/anthropic": "anthropic"
    default: throw ServiceCommunityProviderError.unsupportedProtocol(npm)
    }
  }

  static func upstreamURL(base: String, protocolName: String) throws -> String {
    let suffix: String
    switch protocolName {
    case "chat": suffix = "/chat/completions"
    case "responses": suffix = "/responses"
    case "anthropic": suffix = "/messages"
    default: throw ServiceCommunityProviderError.unsupportedProtocol(protocolName)
    }
    if base.isEmpty { return suffix }
    guard var url = URLComponents(string: base),
      ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      url.host?.isEmpty == false, url.user == nil, url.password == nil
    else { throw ServiceCommunityProviderError.modelUnavailable }
    if !url.path.hasSuffix(suffix) {
      let path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
      url.path = path + suffix
    }
    guard let result = url.url?.absoluteString else {
      throw ServiceCommunityProviderError.modelUnavailable
    }
    return result
  }

  static func encodedID(_ value: String) -> String {
    Data(value.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

extension Optional where Wrapped == String {
  fileprivate var nonEmpty: String? { flatMap { $0.isEmpty ? nil : $0 } }
}
