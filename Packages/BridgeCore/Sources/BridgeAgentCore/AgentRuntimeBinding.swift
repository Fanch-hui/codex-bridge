import Foundation

public enum DeepSeekHarnessConnectionMode: String, Codable, CaseIterable, Sendable {
  case acp
  case nativeDesktop = "native-desktop"
}

public struct AgentRuntimeBinding: Codable, Equatable, Sendable {
  public let connectionMode: DeepSeekHarnessConnectionMode
  public let profileID: String?
  public let requestID: String

  public init(
    connectionMode: DeepSeekHarnessConnectionMode, profileID: String? = nil, requestID: String
  ) {
    self.connectionMode = connectionMode
    self.profileID = profileID
    self.requestID = requestID
  }
}
