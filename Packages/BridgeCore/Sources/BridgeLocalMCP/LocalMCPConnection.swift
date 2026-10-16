import BridgeIPC
import Foundation
import MCP

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct LocalMCPConnection: Sendable {
  let endpoint: URL
  let token: String

  init(configuration: IPCLocalMCPConnectionResponse) throws {
    guard let url = URL(string: configuration.localMCPURL),
      url.scheme == "http",
      let host = url.host,
      ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host),
      url.path == "/mcp", url.port != nil,
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      !configuration.token.isEmpty,
      !configuration.token.contains("\r"), !configuration.token.contains("\n")
    else { throw LocalMCPError.invalidConfiguration }
    endpoint = url
    token = configuration.token
  }

  func transport() -> HTTPClientTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 320
    configuration.timeoutIntervalForResource = 330
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.connectionProxyDictionary = [:]
    return HTTPClientTransport(
      endpoint: endpoint, configuration: configuration, streaming: false,
      requestModifier: { [token] request in
        var request = request
        request.setValue(token, forHTTPHeaderField: "X-Codex-Bridge-Token")
        return request
      }
    )
  }

  func closeSession(_ sessionID: String?, protocolVersion: String?) async {
    guard let sessionID else { return }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 2
    configuration.timeoutIntervalForResource = 2
    configuration.connectionProxyDictionary = [:]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "DELETE"
    request.setValue(token, forHTTPHeaderField: "X-Codex-Bridge-Token")
    request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
    request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
    _ = try? await session.data(for: request)
  }
}

enum LocalMCPError: Error {
  case invalidConfiguration
  case inputOverflow
  case closed
}
