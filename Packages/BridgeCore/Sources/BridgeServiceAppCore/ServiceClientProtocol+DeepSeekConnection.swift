import BridgeIPC

extension BridgeServiceClientProtocol {
  public func connectAgentInstallation(
    providerID: String, baseURL: String?, apiKey: String?,
    alwaysProceedConfirmed: Bool, qoderDistribution: String?, installationID: String?,
    inferenceProtocol: String?, catalogBaseURL: String?
  ) async throws -> IPCAgentInstallationSummary {
    guard inferenceProtocol == nil, catalogBaseURL == nil else {
      throw BridgeServiceClientError.unavailable
    }
    return try await connectAgentInstallation(
      providerID: providerID, baseURL: baseURL, apiKey: apiKey,
      alwaysProceedConfirmed: alwaysProceedConfirmed,
      qoderDistribution: qoderDistribution, installationID: installationID)
  }
}
