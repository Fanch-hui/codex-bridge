import Foundation

public struct AgentNativeSessionDirectoryScope: Codable, Equatable, Sendable {
  public let providerID: AgentProviderID
  public let installationID: AgentInstallationID
  public let projectID: String
  public let projectRoot: String
  public let region: String?

  public init(
    providerID: AgentProviderID,
    installationID: AgentInstallationID,
    projectID: String,
    projectRoot: String,
    region: String? = nil
  ) throws {
    try AgentValidation.identifier(
      providerID.rawValue, field: "history.provider", maximumBytes: 128)
    try AgentValidation.identifier(
      installationID.rawValue, field: "history.installation", maximumBytes: 256)
    try AgentValidation.identifier(projectID, field: "history.project", maximumBytes: 128)
    try AgentValidation.absolutePath(projectRoot, field: "history.projectRoot")
    try AgentValidation.optionalIdentifier(region, field: "history.region", maximumBytes: 64)
    self.providerID = providerID
    self.installationID = installationID
    self.projectID = projectID
    self.projectRoot = projectRoot
    self.region = region
  }
}

public struct AgentNativeSessionPageRequest: Codable, Equatable, Sendable {
  public let offset: Int
  public let limit: Int

  public init(offset: Int = 0, limit: Int = 50) throws {
    guard offset >= 0, (1...100).contains(limit) else {
      throw AgentNativeSessionDirectoryError.invalidRequest
    }
    self.offset = offset
    self.limit = limit
  }
}

public struct AgentNativeSessionSummary: Codable, Equatable, Sendable {
  public let sessionID: String
  public let title: String
  public let firstPrompt: String?
  public let createdAt: Date?
  public let updatedAt: Date?
  public let messageCount: Int?
  public let isIndexed: Bool

  public init(
    sessionID: String,
    title: String,
    firstPrompt: String? = nil,
    createdAt: Date? = nil,
    updatedAt: Date? = nil,
    messageCount: Int?,
    isIndexed: Bool
  ) throws {
    try AgentValidation.identifier(sessionID, field: "history.sessionID", maximumBytes: 256)
    try AgentValidation.text(title, field: "history.title", maximumBytes: 4_096)
    try AgentValidation.optionalText(firstPrompt, field: "history.firstPrompt", maximumBytes: 8_192)
    guard messageCount.map({ $0 >= 0 }) ?? true else {
      throw AgentNativeSessionDirectoryError.invalidRequest
    }
    self.sessionID = sessionID
    self.title = title
    self.firstPrompt = firstPrompt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.messageCount = messageCount
    self.isIndexed = isIndexed
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
}

public struct AgentNativeSessionPage: Codable, Equatable, Sendable {
  public let sessions: [AgentNativeSessionSummary]
  public let nextOffset: Int?

  public init(sessions: [AgentNativeSessionSummary], nextOffset: Int?) {
    self.sessions = sessions
    self.nextOffset = nextOffset
  }

  private enum CodingKeys: String, CodingKey {
    case sessions
    case nextOffset = "next_offset"
  }
}

public struct AgentNativeSessionMessage: Codable, Equatable, Sendable {
  public let messageID: String
  public let role: String
  public let content: String
  public let createdAt: Date?

  public init(messageID: String, role: String, content: String, createdAt: Date? = nil) throws {
    try AgentValidation.identifier(messageID, field: "history.messageID", maximumBytes: 256)
    try AgentValidation.identifier(role, field: "history.role", maximumBytes: 64)
    try AgentValidation.streamText(content, field: "history.content", maximumBytes: 256 * 1_024)
    self.messageID = messageID
    self.role = role
    self.content = content
    self.createdAt = createdAt
  }

  private enum CodingKeys: String, CodingKey {
    case messageID = "message_id"
    case role
    case content
    case createdAt = "created_at"
  }
}

public struct AgentNativeSessionTranscriptPage: Codable, Equatable, Sendable {
  public let sessionID: String
  public let messages: [AgentNativeSessionMessage]
  public let nextOffset: Int?

  public init(sessionID: String, messages: [AgentNativeSessionMessage], nextOffset: Int?) {
    self.sessionID = sessionID
    self.messages = messages
    self.nextOffset = nextOffset
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case messages
    case nextOffset = "next_offset"
  }
}

public struct AgentNativeSessionIndexReceipt: Codable, Equatable, Sendable {
  public let sessionID: String
  public let projectID: String
  public let installationID: String
  public let region: String?
  public let indexedAt: Date

  public init(scope: AgentNativeSessionDirectoryScope, sessionID: String, indexedAt: Date = Date())
  {
    self.sessionID = sessionID
    projectID = scope.projectID
    installationID = scope.installationID.rawValue
    region = scope.region
    self.indexedAt = indexedAt
  }

  private enum CodingKeys: String, CodingKey {
    case sessionID = "session_id"
    case projectID = "project_id"
    case installationID = "installation_id"
    case region
    case indexedAt = "indexed_at"
  }
}

public enum AgentNativeSessionDirectoryError: Error, Equatable, LocalizedError, Sendable {
  case invalidRequest
  case unavailable
  case sessionNotFound
  case activeSession
  case scopeMismatch
  case runtimeFailure

  public var errorDescription: String? {
    switch self {
    case .invalidRequest: "The native session request is invalid."
    case .unavailable: "Native session management is unavailable for this Agent installation."
    case .sessionNotFound: "The native Agent session no longer exists in this project."
    case .activeSession: "The native Agent session is currently active."
    case .scopeMismatch:
      "The native Agent session does not belong to this installation and project."
    case .runtimeFailure: "The native Agent session operation failed."
    }
  }
}

public protocol AgentNativeSessionDirectoryManaging: Sendable {
  func listNativeSessions(
    scope: AgentNativeSessionDirectoryScope,
    installation: AgentInstallation,
    page: AgentNativeSessionPageRequest
  ) async throws -> AgentNativeSessionPage

  func readNativeSession(
    sessionID: String,
    scope: AgentNativeSessionDirectoryScope,
    installation: AgentInstallation,
    page: AgentNativeSessionPageRequest
  ) async throws -> AgentNativeSessionTranscriptPage

  func renameNativeSession(
    sessionID: String,
    title: String,
    scope: AgentNativeSessionDirectoryScope,
    installation: AgentInstallation
  ) async throws -> AgentNativeSessionSummary

  func deleteNativeSession(
    sessionID: String,
    scope: AgentNativeSessionDirectoryScope,
    installation: AgentInstallation
  ) async throws

  func indexNativeSession(
    sessionID: String,
    scope: AgentNativeSessionDirectoryScope,
    installation: AgentInstallation
  ) async throws -> AgentNativeSessionIndexReceipt

  func isIndexedNativeSession(
    sessionID: String,
    scope: AgentNativeSessionDirectoryScope,
    installation: AgentInstallation
  ) async throws -> Bool
}

public protocol AgentNativeSessionDirectoryProviding: Sendable {
  var nativeSessionDirectoryManager: (any AgentNativeSessionDirectoryManaging)? { get }
}
