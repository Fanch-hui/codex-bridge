import BridgeIPC

extension BridgeServiceClientProtocol {
  public func projectWriteConcurrency() async throws -> Int {
    throw BridgeServiceClientError.unavailable
  }

  public func setProjectWriteConcurrency(_ limit: Int) async throws {
    throw BridgeServiceClientError.unavailable
  }
}
