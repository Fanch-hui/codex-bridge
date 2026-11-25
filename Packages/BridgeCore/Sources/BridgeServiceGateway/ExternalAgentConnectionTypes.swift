import Foundation

public enum ExternalAgentConnectionAgent: String, Codable, Equatable, Sendable {
  case codex
  case codexDesktop = "codex_desktop"
  case claude
  case claudeDesktop = "claude_desktop"
  case pi
  case openCode1 = "opencode1"
  case openCode2 = "opencode2"
}

/// Token limits and reasoning levels the gateway knows for a model; written into agent
/// configurations that accept them.
public struct ExternalAgentModelLimit: Equatable, Sendable {
  public let contextWindow: Int?
  public let maxOutputTokens: Int?
  public let reasoningEfforts: [String]?

  public init(contextWindow: Int?, maxOutputTokens: Int?, reasoningEfforts: [String]? = nil) {
    self.contextWindow = contextWindow
    self.maxOutputTokens = maxOutputTokens
    self.reasoningEfforts = reasoningEfforts
  }
}

public struct ExternalAgentConnectionPreview: Codable, Equatable, Sendable {
  public let id: UUID
  public let agent: ExternalAgentConnectionAgent
  public let configurationURL: URL
  public let fields: [[String]]
}

public struct ExternalAgentConnectionReceipt: Codable, Equatable, Sendable {
  public let secretReference: String

  public init(previewID: UUID) {
    secretReference = "agent-connection.\(previewID.uuidString.lowercased())"
  }
}

public enum ExternalAgentConnectionError: Error, Equatable, Sendable {
  case invalidConfiguration
  case invalidPreview
  case configurationChanged
  case activeCodexCoexistence
  case unreadableCodexPromptCatalog
  case conflictingFields([[String]])
  case editorFailed(String)
  case editorUnavailable
  case editorProcessStillRunning
}

public struct ExternalAgentConnectionCleanupFailure: Error {
  public enum Operation: String, Equatable, Sendable {
    case editor
    case publish
    case apply
    case revert
  }

  public let operation: Operation
  public let operationError: (any Error)?
  public let cleanupError: any Error
}
