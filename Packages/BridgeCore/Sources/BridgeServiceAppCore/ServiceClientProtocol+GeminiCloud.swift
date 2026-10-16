import BridgeIPC

extension BridgeServiceClientProtocol {
  public func geminiCloudStatus() async throws -> IPCGeminiCloudStatus {
    throw BridgeServiceClientError.unavailable
  }

  public func configureGeminiCloud(_ value: IPCGeminiCloudConfiguration) async throws
    -> IPCGeminiCloudStatus
  {
    throw BridgeServiceClientError.unavailable
  }

  public func exportGeminiCloudConfiguration(kind: IPCGeminiCloudExportKind) async throws -> String
  {
    throw BridgeServiceClientError.unavailable
  }
}
