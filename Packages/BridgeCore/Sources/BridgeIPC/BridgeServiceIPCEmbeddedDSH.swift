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

extension BridgeServiceClient {
  public func embeddedDSH(_ request: IPCEmbeddedDSHRequest) async throws
    -> IPCEmbeddedDSHResponse
  {
    try await call(operation: .embeddedDSH, payload: request)
  }
}
