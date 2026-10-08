import BridgeMCP

public enum IPCWorkbenchWorkspaceAction: String, Codable, Sendable {
  case listDirectory, readFile, gitStatus, gitDiff, previewWrite, applyWrite
}

public struct IPCWorkbenchWorkspaceRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let action: IPCWorkbenchWorkspaceAction
  public let relativePath: String?
  public let cursor: String?
  public let startLine: Int
  public let lineCount: Int
  public let limit: Int
  public let content: String?
  public let expectedSHA256: String?
  public let operationID: String?
  public let clientRequestID: String
  public let confirmed: Bool

  public init(
    projectID: String, action: IPCWorkbenchWorkspaceAction, relativePath: String? = nil,
    cursor: String? = nil, startLine: Int = 1, lineCount: Int = 1_000, limit: Int = 100,
    content: String? = nil, expectedSHA256: String? = nil, operationID: String? = nil,
    clientRequestID: String, confirmed: Bool = false
  ) {
    self.projectID = projectID
    self.action = action
    self.relativePath = relativePath
    self.cursor = cursor
    self.startLine = startLine
    self.lineCount = lineCount
    self.limit = limit
    self.content = content
    self.expectedSHA256 = expectedSHA256
    self.operationID = operationID
    self.clientRequestID = clientRequestID
    self.confirmed = confirmed
  }
}

public struct IPCWorkbenchGitEntry: Codable, Equatable, Sendable {
  public let relativePath: String
  public let originalPath: String?
  public let indexStatus: String
  public let worktreeStatus: String

  public init(
    relativePath: String, originalPath: String? = nil, indexStatus: String, worktreeStatus: String
  ) {
    self.relativePath = relativePath
    self.originalPath = originalPath
    self.indexStatus = indexStatus
    self.worktreeStatus = worktreeStatus
  }
}

public struct IPCWorkbenchGitStatus: Codable, Equatable, Sendable {
  public let state: String
  public let entries: [IPCWorkbenchGitEntry]
  public let truncated: Bool

  public init(state: String, entries: [IPCWorkbenchGitEntry] = [], truncated: Bool = false) {
    self.state = state
    self.entries = entries
    self.truncated = truncated
  }
}

public struct IPCWorkbenchGitDiff: Codable, Equatable, Sendable {
  public let relativePath: String
  public let text: String
  public let truncated: Bool

  public init(relativePath: String, text: String, truncated: Bool) {
    self.relativePath = relativePath
    self.text = text
    self.truncated = truncated
  }
}

public struct IPCWorkbenchWorkspaceResponse: Codable, Equatable, Sendable {
  public let projectID: String
  public let action: IPCWorkbenchWorkspaceAction
  public var directory: MCPProjectDirectoryPage?
  public var file: MCPProjectFileReadPage?
  public var git: IPCWorkbenchGitStatus?
  public var diff: IPCWorkbenchGitDiff?
  public var preview: MCPDirectMutationPreview?
  public var mutation: MCPDirectMutationReceipt?

  public init(projectID: String, action: IPCWorkbenchWorkspaceAction) {
    self.projectID = projectID
    self.action = action
  }
}

extension BridgeServiceClient {
  public func workbenchWorkspace(_ request: IPCWorkbenchWorkspaceRequest) async throws
    -> IPCWorkbenchWorkspaceResponse
  {
    try await call(operation: .workbenchWorkspace, payload: request)
  }
}
