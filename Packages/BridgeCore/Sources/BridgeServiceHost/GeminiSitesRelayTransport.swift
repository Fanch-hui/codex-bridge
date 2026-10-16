import BridgeMCP
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct GeminiSitesRelayRequest: Codable, Sendable {
  let id: String
  let method: String
  let headers: [String: String]
  let body: String
}

struct GeminiSitesRelayCompletion: Codable, Sendable {
  let id: String
  let status: Int
  let headers: [String: String]
  let body: String
}

enum GeminiCloudError: Error, LocalizedError {
  case invalidAddress
  case notConfigured
  case relayAuthentication
  case relayHTTP(Int)
  case invalidResponse

  var errorDescription: String? {
    switch self {
    case .invalidAddress:
      "请输入 HTTPS 网站根地址；Sites 地址须为公开的 chatgpt.site 网站，不包含路径、查询或访问凭据。"
    case .notConfigured:
      "请先保存云 MCP 的网站地址。"
    case .relayAuthentication:
      "Sites 托管配置不匹配，请重新复制托管配置并更新网站环境变量。"
    case .relayHTTP(let status):
      "Sites 连接返回 HTTP \(status)，请检查网站是否公开、模板是否已部署。"
    case .invalidResponse:
      "Sites 返回的转发数据无效，请检查部署的模板版本。"
    }
  }
}

final class GeminiSitesRelayTransport: @unchecked Sendable {
  private let remote: URLSession
  private let local: URLSession
  private let baseURL: URL
  private let relayKey: String
  private let endpoint: URL
  private let credential: String
  private static let requestHeaders: Set<String> = [
    "accept", "content-type", "mcp-session-id", "mcp-protocol-version", "mcp-method",
    "mcp-name", "last-event-id",
  ]
  private static let responseHeaders: Set<String> = [
    "content-type", "mcp-session-id", "mcp-protocol-version",
  ]

  init(baseURL: URL, relayKey: String, endpoint: URL, credential: String) {
    self.baseURL = baseURL
    self.relayKey = relayKey
    self.endpoint = endpoint
    self.credential = credential
    remote = Self.session(loopback: false)
    local = Self.session(loopback: true)
  }

  func close() {
    remote.invalidateAndCancel()
    local.invalidateAndCancel()
  }

  func poll(limit: Int) async throws -> [GeminiSitesRelayRequest] {
    struct Poll: Encodable { let limit: Int }
    struct Batch: Decodable { let requests: [GeminiSitesRelayRequest] }
    let data = try await send(
      path: "api/bridge/poll", body: JSONEncoder().encode(Poll(limit: limit)))
    guard data.count <= 6 * 1_024 * 1_024,
      let batch = try? JSONDecoder().decode(Batch.self, from: data),
      batch.requests.count <= limit,
      Set(batch.requests.map(\.id)).count == batch.requests.count
    else { throw GeminiCloudError.invalidResponse }
    return batch.requests
  }

  func forward(_ job: GeminiSitesRelayRequest) async -> GeminiSitesRelayCompletion {
    do {
      guard ["POST", "DELETE"].contains(job.method),
        !job.id.isEmpty, job.id.utf8.count <= 128,
        let body = Data(base64Encoded: job.body), body.count <= 1_024 * 1_024
      else { throw GeminiCloudError.invalidResponse }
      var request = URLRequest(url: endpoint)
      request.httpMethod = job.method
      request.httpBody = body.isEmpty ? nil : body
      for (name, value) in job.headers where Self.requestHeaders.contains(name.lowercased()) {
        guard !value.contains("\r"), !value.contains("\n") else {
          throw GeminiCloudError.invalidResponse
        }
        request.setValue(value, forHTTPHeaderField: name)
      }
      request.setValue(
        credential, forHTTPHeaderField: MCPHTTPConfiguration.tunnelAuthenticationHeader)
      let (data, response) = try await local.data(for: request)
      guard let http = response as? HTTPURLResponse, data.count <= 8 * 1_024 * 1_024 else {
        throw GeminiCloudError.invalidResponse
      }
      var headers: [String: String] = [:]
      for (name, value) in http.allHeaderFields {
        let name = String(describing: name).lowercased()
        if Self.responseHeaders.contains(name) { headers[name] = String(describing: value) }
      }
      return .init(
        id: job.id, status: http.statusCode, headers: headers, body: data.base64EncodedString())
    } catch {
      return .init(
        id: job.id, status: 502, headers: ["content-type": "application/json"],
        body: Data("{\"error\":\"bridge_request_unavailable\"}".utf8).base64EncodedString())
    }
  }

  func complete(_ result: GeminiSitesRelayCompletion) async throws {
    _ = try await send(path: "api/bridge/complete", body: JSONEncoder().encode(result))
  }

  private func send(path: String, body: Data) async throws -> Data {
    var request = URLRequest(url: baseURL.appendingPathComponent(path))
    request.httpMethod = "POST"
    request.httpBody = body
    request.timeoutInterval = 20
    request.setValue("Bearer \(relayKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let (data, response) = try await remote.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw GeminiCloudError.invalidResponse }
    if http.statusCode == 401 || http.statusCode == 403 {
      throw GeminiCloudError.relayAuthentication
    }
    guard (200...299).contains(http.statusCode) else {
      throw GeminiCloudError.relayHTTP(http.statusCode)
    }
    return data
  }

  private static func session(loopback: Bool) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 320
    configuration.timeoutIntervalForResource = 330
    if loopback { configuration.connectionProxyDictionary = [:] }
    return URLSession(
      configuration: configuration, delegate: GeminiCloudRedirectPolicy(), delegateQueue: nil)
  }
}

private final class GeminiCloudRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
