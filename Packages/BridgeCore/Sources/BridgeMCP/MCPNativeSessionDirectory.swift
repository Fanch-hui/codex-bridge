import BridgeAgentCore
import Foundation

public enum MCPNativeSessionDirectoryOperation: String, Codable, Sendable {
  case list
  case read
  case index
  case rename
  case delete
}

public struct MCPNativeSessionDirectoryRequest: Codable, Equatable, Sendable {
  public let operation: MCPNativeSessionDirectoryOperation
  public let projectID: String
  public let installationID: String
  public let sessionID: String?
  public let offset: Int
  public let limit: Int
  public let title: String?
  public let confirmed: Bool

  public init(
    operation: MCPNativeSessionDirectoryOperation,
    projectID: String,
    installationID: String,
    sessionID: String? = nil,
    offset: Int = 0,
    limit: Int = 50,
    title: String? = nil,
    confirmed: Bool = false
  ) {
    self.operation = operation
    self.projectID = projectID
    self.installationID = installationID
    self.sessionID = sessionID
    self.offset = offset
    self.limit = limit
    self.title = title
    self.confirmed = confirmed
  }

  private enum CodingKeys: String, CodingKey {
    case operation
    case projectID = "project_id"
    case installationID = "installation_id"
    case sessionID = "session_id"
    case offset
    case limit
    case title
    case confirmed
  }
}

public struct MCPNativeSessionDirectoryResponse: Codable, Equatable, Sendable {
  public let page: AgentNativeSessionPage?
  public let transcript: AgentNativeSessionTranscriptPage?
  public let summary: AgentNativeSessionSummary?
  public let receipt: AgentNativeSessionIndexReceipt?
  public let deleted: Bool

  public init(
    page: AgentNativeSessionPage? = nil,
    transcript: AgentNativeSessionTranscriptPage? = nil,
    summary: AgentNativeSessionSummary? = nil,
    receipt: AgentNativeSessionIndexReceipt? = nil,
    deleted: Bool = false
  ) {
    self.page = page
    self.transcript = transcript
    self.summary = summary
    self.receipt = receipt
    self.deleted = deleted
  }

  private enum CodingKeys: String, CodingKey {
    case page
    case transcript
    case summary
    case receipt
    case deleted
  }
}
