import BridgeAgentCore
import Foundation

public struct MCPNativeSessionSummaryOutput: Encodable, Sendable {
  public let sessionID: String
  public let title: String
  public let firstPrompt: String?
  public let createdAt: String?
  public let updatedAt: String?
  public let messageCount: Int?
  public let isIndexed: Bool

  public init(_ value: AgentNativeSessionSummary) {
    sessionID = value.sessionID
    title = value.title
    firstPrompt = value.firstPrompt
    createdAt = Self.iso8601(value.createdAt)
    updatedAt = Self.iso8601(value.updatedAt)
    messageCount = value.messageCount
    isIndexed = value.isIndexed
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case title
    case firstPrompt = "first_prompt"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case messageCount = "message_count"
    case isIndexed = "is_indexed"
  }

  private static func iso8601(_ date: Date?) -> String? {
    guard let date else { return nil }
    return ISO8601DateFormatter().string(from: date)
  }
}

public struct MCPNativeSessionPageOutput: Encodable, Sendable {
  public let sessions: [MCPNativeSessionSummaryOutput]
  public let nextOffset: Int?

  public init(_ value: AgentNativeSessionPage) {
    sessions = value.sessions.map(MCPNativeSessionSummaryOutput.init)
    nextOffset = value.nextOffset
  }

  private enum CodingKeys: String, CodingKey {
    case sessions
    case nextOffset = "next_offset"
  }
}

public struct MCPNativeSessionTranscriptOutput: Encodable, Sendable {
  public let sessionID: String
  public let messages: [MCPNativeSessionMessageOutput]
  public let nextOffset: Int?

  public init(_ value: AgentNativeSessionTranscriptPage) {
    sessionID = value.sessionID
    messages = value.messages.map(MCPNativeSessionMessageOutput.init)
    nextOffset = value.nextOffset
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case messages
    case nextOffset = "next_offset"
  }
}

public struct MCPNativeSessionMessageOutput: Encodable, Sendable {
  public let messageID: String
  public let role: String
  public let content: String
  public let createdAt: String?

  public init(_ value: AgentNativeSessionMessage) {
    messageID = value.messageID
    role = value.role
    content = value.content
    createdAt = value.createdAt.map { ISO8601DateFormatter().string(from: $0) }
  }

  private enum CodingKeys: String, CodingKey {
    case messageID = "message_id"
    case role
    case content
    case createdAt = "created_at"
  }
}

public struct MCPNativeSessionIndexOutput: Encodable, Sendable {
  public let sessionID: String
  public let projectID: String
  public let installationID: String
  public let region: String?
  public let indexedAt: String

  public init(_ value: AgentNativeSessionIndexReceipt) {
    sessionID = value.sessionID
    projectID = value.projectID
    installationID = value.installationID
    region = value.region
    indexedAt = ISO8601DateFormatter().string(from: value.indexedAt)
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case projectID = "project_id"
    case installationID = "installation_id"
    case region
    case indexedAt = "indexed_at"
  }
}

public struct MCPNativeSessionDeleteOutput: Encodable, Sendable {
  public let deleted = true

  public init() {}
}
