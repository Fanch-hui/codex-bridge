import Foundation

public struct IPCProviderGatewayRequest: Codable, Equatable, Sendable {
  public let action: String
  public let payloadJSON: String

  public init(action: String, payloadJSON: String = "{}") {
    self.action = action
    self.payloadJSON = payloadJSON
  }
}

public struct IPCProviderGatewayResponse: Codable, Equatable, Sendable {
  public let resultJSON: String

  public init(resultJSON: String) {
    self.resultJSON = resultJSON
  }
}

extension BridgeServiceClient {
  public func providerGateway(_ request: IPCProviderGatewayRequest) async throws
    -> IPCProviderGatewayResponse
  {
    try await call(operation: .providerGateway, payload: request)
  }
}
