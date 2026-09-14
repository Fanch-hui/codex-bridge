import Foundation

public struct IPCDeepSeekSearchConfiguration: Codable, Equatable, Sendable {
  public let baseURL: String?
  public init(baseURL: String? = nil) { self.baseURL = baseURL }
}

extension BridgeServiceClient {
  public func deepSeekSearchConfiguration() async throws -> IPCDeepSeekSearchConfiguration {
    try await call(
      operation: .getDeepSeekSearchConfiguration, payload: Optional<IPCMutationResponse>.none)
  }
  public func saveDeepSeekSearchConfiguration(_ request: IPCDeepSeekSearchConfiguration)
    async throws -> IPCDeepSeekSearchConfiguration
  {
    try await call(operation: .saveDeepSeekSearchConfiguration, payload: request)
  }
}
