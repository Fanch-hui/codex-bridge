import Foundation

extension BridgeServiceClient {
  public func deepSeekHarnessMCPServers() async throws -> IPCDeepSeekHarnessMCPListResponse {
    try await deepSeekHarnessMCPServers(scope: nil)
  }

  public func deepSeekHarnessMCPServers(scope: String?) async throws
    -> IPCDeepSeekHarnessMCPListResponse
  {
    try await call(
      operation: .listDeepSeekHarnessMCPServers,
      payload: IPCAgentMCPListRequest(scope: scope)
    )
  }

  public func saveDeepSeekHarnessMCPServer(
    _ request: IPCDeepSeekHarnessMCPServerInput
  ) async throws -> IPCDeepSeekHarnessMCPServerSummary {
    try await call(operation: .saveDeepSeekHarnessMCPServer, payload: request)
  }

  public func deleteDeepSeekHarnessMCPServer(id: String) async throws {
    try await deleteDeepSeekHarnessMCPServer(id: id, scope: nil)
  }

  public func deleteDeepSeekHarnessMCPServer(id: String, scope: String?) async throws {
    let _: IPCMutationResponse = try await call(
      operation: .deleteDeepSeekHarnessMCPServer,
      payload: IPCDeepSeekHarnessMCPDeleteRequest(id: id, scope: scope)
    )
  }
}
