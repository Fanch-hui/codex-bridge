import BridgeIPC
import Foundation

extension ServiceComposition {
  public func geminiCloudStatus() async throws -> IPCGeminiCloudStatus {
    try await geminiCloud.status()
  }

  public func configureGeminiCloud(_ value: IPCGeminiCloudConfiguration) async throws
    -> IPCGeminiCloudStatus
  {
    let endpoint = try await startLocalMCP()
    try await geminiCloud.configure(value, endpoint: endpoint.localURL)
    return try await geminiCloud.status()
  }

  public func exportGeminiCloudConfiguration(kind: IPCGeminiCloudExportKind) async throws -> String
  {
    if kind == .sitesPrompt { return GeminiSitesSetupGuide.prompt }
    let endpoint = try await startLocalMCP()
    return try await geminiCloud.export(kind, endpoint: endpoint.localURL)
  }
}
