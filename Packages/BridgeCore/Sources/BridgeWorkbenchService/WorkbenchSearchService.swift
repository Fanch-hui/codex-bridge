import BridgeACP
import BridgeSecurity
import BridgeServiceCore
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

package struct WorkbenchSearchError: Error, LocalizedError, Equatable, Sendable {
  package let code: String
  package let message: String
  package let retryable: Bool

  package var errorDescription: String? { message }
}

/// The selected search service and its credential are saved together in the system secret store.
actor WorkbenchSearchService {
  typealias Request = @Sendable (URLRequest) async throws -> (Data, Int)

  private enum Provider: String, Codable {
    case brave
    case tavily
    case custom
  }

  private enum Format: String, Codable {
    case brave
    case tavily
    case searxng
  }

  private struct Configuration: Codable {
    let provider: Provider
    let apiKey: String
    let endpoint: String?
    let format: Format?
  }

  private static let reference = SecretReference(rawValue: "workbench.search.service")
  private let secrets: any SecretStore
  private let request: Request
  private let changes = AsyncMutex()

  init(
    secretStore: any SecretStore,
    request: @escaping Request = WorkbenchSearchHTTPClient.send
  ) {
    self.secrets = secretStore
    self.request = request
  }

  func settings() throws -> ACPJSONValue {
    Self.settingsValue(try configuration())
  }

  func save(_ input: ACPJSONValue) async throws -> ACPJSONValue {
    guard let name = input["provider"]?.stringValue, let provider = Provider(rawValue: name) else {
      throw Self.error("invalid_provider", "请选择搜索服务。")
    }
    guard input["apiKey"] == nil || input["apiKey"]?.stringValue != nil else {
      throw Self.error("invalid_key", "请输入搜索服务的 API 密钥。")
    }
    let key = (input["apiKey"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard provider == .custom || !key.isEmpty, key.utf8.count <= 4_096,
      key.utf8.allSatisfy({ (0x21...0x7E).contains($0) })
    else {
      throw Self.error("invalid_key", "请输入有效的 API 密钥。")
    }
    let candidate: Configuration
    if provider == .custom {
      guard let name = input["format"]?.stringValue, let format = Format(rawValue: name) else {
        throw Self.error("invalid_format", "请选择搜索服务的接口格式。")
      }
      guard let value = input["endpoint"]?.stringValue else {
        throw Self.error("invalid_endpoint", "请输入有效的搜索服务地址。")
      }
      candidate = Configuration(
        provider: provider, apiKey: key, endpoint: try Self.endpoint(value), format: format)
    } else {
      candidate = Configuration(provider: provider, apiKey: key, endpoint: nil, format: nil)
    }
    await changes.acquire()
    defer { changes.release() }
    try Task.checkCancellation()
    _ = try await search(query: "example.com", using: candidate)
    try Task.checkCancellation()
    try secrets.store(JSONEncoder().encode(candidate), for: Self.reference)
    return Self.settingsValue(candidate)
  }

  func remove() async throws -> ACPJSONValue {
    await changes.acquire()
    defer { changes.release() }
    try Task.checkCancellation()
    do {
      try secrets.remove(Self.reference)
    } catch SecretStoreError.notFound {
      // Clearing an already empty configuration is complete.
    }
    return Self.settingsValue(nil)
  }

  func search(_ input: ACPJSONValue) async throws -> ACPJSONValue {
    guard let text = input["query"]?.stringValue else {
      throw Self.error("invalid_query", "请输入搜索内容。")
    }
    let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty, query.utf8.count <= 4_096 else {
      throw Self.error("invalid_query", "搜索内容为空或过长。")
    }
    guard let config = try configuration() else {
      throw Self.error("not_configured", "请先在工作台设置中配置联网搜索。")
    }
    return try await search(query: query, using: config)
  }

  private func configuration() throws -> Configuration? {
    let data: Data
    do {
      data = try secrets.load(Self.reference)
    } catch SecretStoreError.notFound {
      return nil
    }
    do {
      let configuration = try JSONDecoder().decode(Configuration.self, from: data)
      guard
        configuration.provider != .custom
          || (configuration.endpoint != nil && configuration.format != nil)
      else { throw SecretStoreError.invalidStoredValue }
      return configuration
    } catch {
      throw SecretStoreError.invalidStoredValue
    }
  }

  private func search(query: String, using config: Configuration) async throws -> ACPJSONValue {
    let (format, endpoint) = try Self.target(config)
    let request = try Self.makeRequest(
      query: query, format: format, endpoint: endpoint, apiKey: config.apiKey)
    let data: Data
    let status: Int
    do {
      (data, status) = try await self.request(request)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as WorkbenchSearchError {
      throw error
    } catch let error as URLError where error.code == .timedOut {
      throw Self.error("timeout", "搜索服务连接超时，请重试。", retryable: true)
    } catch {
      if Task.isCancelled { throw CancellationError() }
      throw Self.error("connection_failed", "无法连接搜索服务，请检查网络后重试。", retryable: true)
    }
    switch status {
    case 200...299:
      break
    case 403 where format == .searxng:
      throw Self.error("authentication_failed", "搜索服务拒绝访问，请检查鉴权并确认已启用 JSON 输出。")
    case 401, 403:
      throw Self.error("authentication_failed", "搜索服务拒绝了密钥，请检查后重试。")
    case 429:
      throw Self.error("rate_limited", "搜索服务请求过于频繁，请稍后重试。", retryable: true)
    default:
      throw Self.error("service_failed", "搜索服务暂时不可用（HTTP \(status)）。", retryable: status >= 500)
    }
    return try Self.result(data, format: format)
  }

  private static func settingsValue(_ configuration: Configuration?) -> ACPJSONValue {
    var result: [String: ACPJSONValue] = [
      "provider": configuration.map { .string($0.provider.rawValue) } ?? .null
    ]
    if let configuration, configuration.provider == .custom {
      result["endpoint"] = configuration.endpoint.map(ACPJSONValue.string)
      result["format"] = configuration.format.map { .string($0.rawValue) }
    }
    return .object(result)
  }

  private static func error(
    _ code: String, _ message: String, retryable: Bool = false
  ) -> WorkbenchSearchError {
    WorkbenchSearchError(code: "workbench_search_\(code)", message: message, retryable: retryable)
  }

  private static func endpoint(_ value: String) throws -> String {
    let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard address.utf8.count <= 4_096, var components = URLComponents(string: address),
      let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(),
      !host.isEmpty, components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil,
      components.port.map({ (1...65_535).contains($0) }) ?? true,
      scheme == "https"
        || (scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host))
    else {
      throw error("invalid_endpoint", "请输入 HTTPS 地址或本机 HTTP 地址，且不要包含账号、密码、查询参数或片段。")
    }
    components.scheme = scheme
    guard let url = components.url else {
      throw error("invalid_endpoint", "请输入有效的搜索服务地址。")
    }
    return url.absoluteString
  }

  private static func target(_ config: Configuration) throws -> (Format, URL) {
    switch config.provider {
    case .brave: return (.brave, URL(string: "https://api.search.brave.com/res/v1/web/search")!)
    case .tavily: return (.tavily, URL(string: "https://api.tavily.com/search")!)
    case .custom:
      guard let format = config.format, let endpoint = config.endpoint,
        let url = URL(string: endpoint)
      else { throw SecretStoreError.invalidStoredValue }
      return (format, url)
    }
  }

  private static func makeRequest(
    query: String, format: Format, endpoint: URL, apiKey: String
  ) throws -> URLRequest {
    let url: URL
    switch format {
    case .brave, .searxng:
      guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
        throw error("invalid_endpoint", "搜索服务地址无效。")
      }
      components.queryItems = [URLQueryItem(name: "q", value: query)]
      if format == .brave {
        components.queryItems?.append(contentsOf: [
          URLQueryItem(name: "count", value: "5"),
          URLQueryItem(name: "result_filter", value: "web"),
          URLQueryItem(name: "text_decorations", value: "false"),
        ])
      } else {
        components.queryItems?.append(URLQueryItem(name: "format", value: "json"))
      }
      components.percentEncodedQuery = components.percentEncodedQuery?
        .replacingOccurrences(of: "+", with: "%2B")
      guard let result = components.url else {
        throw error("invalid_query", "搜索内容无效。")
      }
      url = result
    case .tavily:
      url = endpoint
    }
    var request = URLRequest(url: url, timeoutInterval: 20)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpShouldHandleCookies = false
    switch format {
    case .brave:
      if !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token") }
    case .tavily:
      request.httpMethod = "POST"
      if !apiKey.isEmpty {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
      }
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try ACPJSONValue.object([
        "query": .string(query), "search_depth": .string("basic"), "max_results": .integer(5),
      ]).encodedData()
    case .searxng:
      if !apiKey.isEmpty {
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
      }
    }
    return request
  }

  private static func result(_ data: Data, format: Format) throws -> ACPJSONValue {
    guard data.count <= WorkbenchSearchHTTPClient.maximumResponseBytes,
      let root = try? JSONDecoder().decode(ACPJSONValue.self, from: data)
    else { throw error("invalid_response", "搜索服务返回了无法读取的数据。", retryable: true) }
    let items: [ACPJSONValue]?
    switch format {
    case .brave:
      if root["web"] == nil || root["web"] == .null, root["type"] == .string("search") {
        items = []
      } else {
        items = root["web"]?["results"]?.arrayValue
      }
    case .tavily, .searxng: items = root["results"]?.arrayValue
    }
    guard let items else {
      throw error("invalid_response", "搜索服务返回了无法读取的数据。", retryable: true)
    }
    let values = items.prefix(5).compactMap { item -> ACPJSONValue? in
      guard let title = item["title"]?.stringValue, !title.isEmpty,
        let address = item["url"]?.stringValue, address.utf8.count <= 4_096,
        let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
        url.host != nil, url.user == nil, url.password == nil
      else { return nil }
      let description =
        (format == .brave ? item["description"] : item["content"])?.stringValue ?? ""
      return .object([
        "title": .string(String(title.prefix(300))),
        "url": .string(address),
        "description": .string(String(description.prefix(2_000))),
      ])
    }
    return .object(["results": .array(values)])
  }
}
