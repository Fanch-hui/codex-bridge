import Foundation

public struct IPCLocalMCPConnectionResponse: Codable, Equatable, Sendable {
  public let localMCPURL: String
  public let token: String

  public init(localMCPURL: String, token: String) {
    self.localMCPURL = localMCPURL
    self.token = token
  }

  private enum CodingKeys: String, CodingKey {
    case localMCPURL = "local_mcp_url"
    case token
  }
}

extension BridgeServiceClient {
  public func localMCPConnection(clientID: String) async throws -> IPCLocalMCPConnectionResponse {
    try await call(
      operation: .getLocalMCPConnection,
      payload: IPCMCPClientRequest(clientID: clientID)
    )
  }
}
