import Foundation

public struct IPCEmbeddedDSHRequest: Codable, Equatable, Sendable {
  public let action: String
  public let payloadJSON: String

  public init(action: String, payloadJSON: String = "{}") {
    self.action = action
    self.payloadJSON = payloadJSON
  }
}

public struct IPCEmbeddedDSHResponse: Codable, Equatable, Sendable {
  public let resultJSON: String

  public init(resultJSON: String) {
    self.resultJSON = resultJSON
  }
}

public struct IPCWorkbenchSettings: Codable, Equatable, Sendable {
  public let enabled: Bool

  public init(enabled: Bool) {
    self.enabled = enabled
  }
}

extension BridgeServiceClient {
  public func workbenchSettings() async throws -> IPCWorkbenchSettings {
    try await call(operation: .getWorkbenchSettings, payload: Optional<IPCMutationResponse>.none)
  }

  public func setWorkbenchEnabled(_ enabled: Bool) async throws -> IPCWorkbenchSettings {
    try await call(operation: .setWorkbenchEnabled, payload: IPCWorkbenchSettings(enabled: enabled))
  }

  public func embeddedDSH(_ request: IPCEmbeddedDSHRequest) async throws
    -> IPCEmbeddedDSHResponse
  {
    try await call(operation: .embeddedDSH, payload: request)
  }
}
