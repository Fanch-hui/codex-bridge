import Foundation

public enum IPCGeminiCloudHosting: String, Codable, CaseIterable, Sendable {
  case sites
  case ngrok
}

public struct IPCGeminiCloudConfiguration: Codable, Equatable, Sendable {
  public let hosting: IPCGeminiCloudHosting
  public let baseURL: String
  public let enabled: Bool

  public init(hosting: IPCGeminiCloudHosting, baseURL: String, enabled: Bool) {
    self.hosting = hosting
    self.baseURL = baseURL
    self.enabled = enabled
  }
}

public struct IPCGeminiCloudStatus: Codable, Equatable, Sendable {
  public let configuration: IPCGeminiCloudConfiguration?
  public let lifecycle: String
  public let message: String?
  public let lastConnectedAt: String?

  public init(
    configuration: IPCGeminiCloudConfiguration? = nil,
    lifecycle: String = "stopped",
    message: String? = nil,
    lastConnectedAt: String? = nil
  ) {
    self.configuration = configuration
    self.lifecycle = lifecycle
    self.message = message
    self.lastConnectedAt = lastConnectedAt
  }
}

public enum IPCGeminiCloudExportKind: String, Codable, Sendable {
  case endpoint
  case sitesEnvironment
  case sitesPrompt
  case ngrokCommand
}

public struct IPCGeminiCloudExportRequest: Codable, Equatable, Sendable {
  public let kind: IPCGeminiCloudExportKind

  public init(kind: IPCGeminiCloudExportKind) {
    self.kind = kind
  }
}

extension BridgeServiceClient {
  public func geminiCloudStatus() async throws -> IPCGeminiCloudStatus {
    try await call(operation: .getGeminiCloudStatus, payload: Optional<IPCMutationResponse>.none)
  }

  public func configureGeminiCloud(_ value: IPCGeminiCloudConfiguration) async throws
    -> IPCGeminiCloudStatus
  {
    try await call(operation: .configureGeminiCloud, payload: value)
  }

  public func exportGeminiCloudConfiguration(kind: IPCGeminiCloudExportKind) async throws -> String
  {
    let result: IPCMCPClientConfigurationExport = try await call(
      operation: .exportGeminiCloudConfiguration,
      payload: IPCGeminiCloudExportRequest(kind: kind)
    )
    return result.configurationJSON
  }
}
