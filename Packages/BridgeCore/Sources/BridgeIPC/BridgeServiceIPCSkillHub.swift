import Foundation

public struct IPCSkillHubRequest: Codable, Equatable, Sendable {
  public let action: String
  public let payloadJSON: String

  public init(action: String, payloadJSON: String = "{}") {
    self.action = action
    self.payloadJSON = payloadJSON
  }
}

public struct IPCSkillHubResponse: Codable, Equatable, Sendable {
  public let resultJSON: String

  public init(resultJSON: String) {
    self.resultJSON = resultJSON
  }
}

extension BridgeServiceClient {
  public func skillHub(_ request: IPCSkillHubRequest) async throws -> IPCSkillHubResponse {
    try await call(operation: .skillHub, payload: request)
  }
}
