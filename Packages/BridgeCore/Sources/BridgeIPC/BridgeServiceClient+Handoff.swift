import BridgeMCP

extension BridgeServiceClient {
  public func taskHandoff(_ request: MCPTaskHandoffRequest) async throws -> MCPTaskHandoffPreview {
    try await call(operation: .taskHandoff, payload: request)
  }
}
