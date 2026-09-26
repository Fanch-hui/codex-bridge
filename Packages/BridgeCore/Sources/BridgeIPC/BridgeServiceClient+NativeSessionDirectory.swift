import BridgeMCP

extension BridgeServiceClient {
  public func manageAgentNativeSessionDirectory(
    _ request: MCPNativeSessionDirectoryRequest
  ) async throws -> MCPNativeSessionDirectoryResponse {
    try await call(operation: .manageAgentNativeSessionDirectory, payload: request)
  }
}
