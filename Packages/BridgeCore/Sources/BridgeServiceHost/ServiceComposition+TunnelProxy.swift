extension ServiceComposition {
  public func setTunnelHTTPProxy(_ httpProxy: String?) async throws -> ServiceTunnelSnapshot {
    try await tunnel.setHTTPProxy(httpProxy)
  }
}
