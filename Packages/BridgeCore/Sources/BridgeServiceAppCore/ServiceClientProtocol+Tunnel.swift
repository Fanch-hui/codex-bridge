import BridgeIPC

extension BridgeServiceClientProtocol {
  public func setTunnelHTTPProxy(_ request: IPCTunnelHTTPProxyRequest) async throws
    -> IPCTunnelStatus
  {
    throw BridgeServiceClientError.unavailable
  }
}
