import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1

extension ModelGatewayHTTPHandler {
  static let allowedRoutes: [String: HTTPMethod] = [
    "/v1/models": .GET,
    "/v1/chat/completions": .POST,
    "/v1/responses": .POST,
    "/v1/messages": .POST,
    "/v1/messages/count_tokens": .POST,
    "/codex/models": .GET,
    "/api/hello": .HEAD,
  ]

  static func parseRoute(uri: String, method: HTTPMethod) -> (path: String, query: String?)? {
    let path: String
    let query: String?
    if uri.hasPrefix("/codex/models?") {
      let prefix = "/codex/models?client_version="
      guard uri.hasPrefix(prefix) else { return nil }
      let version = uri.dropFirst(prefix.count)
      let components = version.split(separator: ".", omittingEmptySubsequences: false)
      guard version.utf8.count <= 40, components.count == 3,
        components.allSatisfy({
          !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) }
        })
      else { return nil }
      path = "/codex/models"
      query = "client_version=\(version)"
    } else if uri == "/codex/models" {
      return nil
    } else if uri == "/v1/messages?beta=true" {
      path = "/v1/messages"
      query = "beta=true"
    } else if uri == "/v1/messages/count_tokens?beta=true" {
      path = "/v1/messages/count_tokens"
      query = "beta=true"
    } else if uri == "/v1/models?limit=1000" {
      path = "/v1/models"
      query = "limit=1000"
    } else {
      path = uri
      query = nil
    }
    guard allowedRoutes[path] == method else { return nil }
    return (path, query)
  }

  static func validAuthority(_ head: HTTPRequestHead, channel: any Channel) -> Bool {
    guard let port = channel.localAddress?.port else { return false }
    let authorities = ["127.0.0.1:\(port)", "localhost:\(port)"]
    let hosts = head.headers["host"]
    guard hosts.count == 1, authorities.contains(hosts[0].lowercased()) else { return false }
    let origins = head.headers["origin"]
    guard origins.count <= 1 else { return false }
    return origins.isEmpty || authorities.map { "http://\($0)" }.contains(origins[0].lowercased())
  }

  static func authenticatedClient(
    _ head: HTTPRequestHead, authenticate: ModelGatewayAuthenticate
  ) -> ModelGatewayClientContext? {
    let authorization = head.headers["authorization"]
    let apiKey = head.headers["x-api-key"]
    let bridgeToken = head.headers["x-codex-bridge-token"]
    let codexGatewayToken = head.headers["x-bridge-gateway-token"]
    let accountID = head.headers["chatgpt-account-id"]
    guard authorization.count <= 1, apiKey.count <= 1, bridgeToken.count <= 1,
      codexGatewayToken.count <= 1, accountID.count <= 1,
      codexGatewayToken.isEmpty || accountID.allSatisfy({ !$0.isEmpty && !$0.contains(",") })
    else { return nil }
    return authenticate(
      ModelGatewayCredentials(
        authorization: authorization, apiKey: apiKey, bridgeToken: bridgeToken,
        codexGatewayToken: codexGatewayToken))
  }

  static func validLength(_ headers: HTTPHeaders, maximum: Int) -> Bool {
    let lengths = headers["content-length"]
    guard lengths.count <= 1 else { return false }
    guard let raw = lengths.first else { return true }
    guard headers["transfer-encoding"].isEmpty,
      !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
      let length = Int(raw), length <= maximum
    else { return false }
    return true
  }

  static func makeRequest(_ input: Request) -> ModelGatewayRequest {
    var headers: [String: String] = [:]
    for (name, value) in input.head.headers {
      let name = name.lowercased()
      guard name != "authorization", name != "x-api-key", name != "x-codex-bridge-token",
        name != "x-bridge-gateway-token", name != "chatgpt-account-id"
      else {
        continue
      }
      if let previous = headers[name] {
        headers[name] = "\(previous), \(value)"
      } else {
        headers[name] = value
      }
    }
    let upstreamAuth: ModelGatewayUpstreamAuth?
    if input.client.authenticatedViaBridgeHeader || input.client.authenticatedViaCodexGatewayHeader
    {
      let auth = ModelGatewayUpstreamAuth(
        authorization: input.head.headers["authorization"].first,
        apiKey: input.head.headers["x-api-key"].first,
        chatGPTAccountID: input.client.authenticatedViaCodexGatewayHeader
          ? input.head.headers["chatgpt-account-id"].first : nil)
      upstreamAuth = auth.hasCredential ? auth : nil
    } else {
      upstreamAuth = nil
    }
    let bytes =
      input.bytes.getBytes(at: input.bytes.readerIndex, length: input.bytes.readableBytes) ?? []
    return ModelGatewayRequest(
      method: input.head.method.rawValue, path: input.path, query: input.query, headers: headers,
      body: Data(bytes), client: input.client, upstreamAuth: upstreamAuth)
  }
}
