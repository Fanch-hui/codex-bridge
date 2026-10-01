import BridgeAgentCore

extension ServiceSettings {
  public func deepSeekHarnessConnectionConfiguration() async throws
    -> DeepSeekHarnessConnectionConfiguration?
  {
    guard let baseURL = try await string(for: .deepSeekHarnessBaseURL) else { return nil }
    let protocolValue = try await string(for: .deepSeekHarnessProtocol)
    return DeepSeekHarnessConnectionConfiguration(
      inferenceProtocol: protocolValue.flatMap(DeepSeekHarnessConnectionProtocol.init(rawValue:)),
      baseURL: baseURL,
      catalogBaseURL: try await string(for: .deepSeekHarnessCatalogBaseURL)
    )
  }

  public func setDeepSeekHarnessConnectionConfiguration(
    _ configuration: DeepSeekHarnessConnectionConfiguration
  ) async throws {
    try await set(configuration.baseURL, for: .deepSeekHarnessBaseURL)
    try await set(configuration.inferenceProtocol.rawValue, for: .deepSeekHarnessProtocol)
    try await set(configuration.catalogBaseURL, for: .deepSeekHarnessCatalogBaseURL)
  }
}
