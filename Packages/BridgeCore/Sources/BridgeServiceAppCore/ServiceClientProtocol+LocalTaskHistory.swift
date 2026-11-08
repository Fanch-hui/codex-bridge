import BridgeIPC
import BridgeMCP

extension BridgeServiceClientProtocol {
  public func localTaskHistory(_ request: IPCTaskRequest) async throws -> MCPServiceTaskSnapshot {
    try await task(request)
  }
}
