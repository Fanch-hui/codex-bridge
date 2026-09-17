import Foundation

extension BridgeServiceClient {
  public func deepSeekHarnessMCPServers() async throws
    -> IPCDeepSeekHarnessMCPListResponse
  {
    try await call(
      operation: .listDeepSeekHarnessMCPServers,
      payload: Optional<IPCMutationResponse>.none
    )
  }

  public func saveDeepSeekHarnessMCPServer(
    _ request: IPCDeepSeekHarnessMCPServerInput
  ) async throws -> IPCDeepSeekHarnessMCPServerSummary {
    try await call(operation: .saveDeepSeekHarnessMCPServer, payload: request)
  }

  public func deleteDeepSeekHarnessMCPServer(id: String) async throws {
    let _: IPCMutationResponse = try await call(
      operation: .deleteDeepSeekHarnessMCPServer,
      payload: IPCDeepSeekHarnessMCPDeleteRequest(id: id)
    )
  }
}
