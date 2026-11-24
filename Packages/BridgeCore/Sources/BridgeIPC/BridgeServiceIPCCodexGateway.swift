import Foundation

public struct IPCCodexGatewayCredentialRequest: Codable, Sendable {
  public let clientID: String

  public init(clientID: String) {
    self.clientID = clientID
  }

  private enum CodingKeys: String, CodingKey {
    case clientID = "client_id"
  }
}

public struct IPCCodexGatewayCredentialResponse: Codable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let token: String

  public init(token: String) {
    self.token = token
  }

  public var description: String { "IPCCodexGatewayCredentialResponse(<redacted>)" }
  public var debugDescription: String { description }
}

extension BridgeServiceClient {
  public func codexGatewayCredential(clientID: String) async throws -> String {
    let response: IPCCodexGatewayCredentialResponse = try await call(
      operation: .exportCodexGatewayCredential,
      payload: IPCCodexGatewayCredentialRequest(clientID: clientID))
    return response.token
  }
}
