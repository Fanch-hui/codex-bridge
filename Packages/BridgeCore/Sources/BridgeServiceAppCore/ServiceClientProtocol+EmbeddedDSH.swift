import BridgeIPC

extension BridgeServiceClientProtocol {
  public func providerGateway(_ request: IPCProviderGatewayRequest) async throws
    -> IPCProviderGatewayResponse
  {
    throw BridgeServiceClientError.unavailable
  }

  public func embeddedDSH(_ request: IPCEmbeddedDSHRequest) async throws
    -> IPCEmbeddedDSHResponse
  {
    throw BridgeServiceClientError.unavailable
  }
}
