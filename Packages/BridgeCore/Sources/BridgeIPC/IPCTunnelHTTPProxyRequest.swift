public struct IPCTunnelHTTPProxyRequest: Codable, Equatable, Sendable {
  public let httpProxy: String?

  public init(httpProxy: String?) {
    self.httpProxy = httpProxy
  }

  private enum CodingKeys: String, CodingKey {
    case httpProxy = "http_proxy"
  }
}
