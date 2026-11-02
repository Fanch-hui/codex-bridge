import BridgeIPC

extension BridgeServiceClientProtocol {
  public func embeddedDSH(_ request: IPCEmbeddedDSHRequest) async throws
    -> IPCEmbeddedDSHResponse
  {
    throw BridgeServiceClientError.unavailable
  }
}
