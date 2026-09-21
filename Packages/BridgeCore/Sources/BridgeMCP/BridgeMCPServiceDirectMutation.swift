import Foundation

public struct MCPDirectMutationRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let kind: String
  public let relativePath: String?
  public let mode: String?
  public let content: String?
  public let expectedSHA256: String?
  public let createParents: Bool
  public let oldText: String?
  public let newText: String?
  public let expectedReplacements: Int?
  public let patch: String?
  public let clientRequestID: String?

  public init(
    projectID: String,
    kind: String,
    relativePath: String? = nil,
    mode: String? = nil,
    content: String? = nil,
    expectedSHA256: String? = nil,
    createParents: Bool = false,
    oldText: String? = nil,
    newText: String? = nil,
    expectedReplacements: Int? = nil,
    patch: String? = nil,
    clientRequestID: String? = nil
  ) {
    self.projectID = projectID
    self.kind = kind
    self.relativePath = relativePath
    self.mode = mode
    self.content = content
    self.expectedSHA256 = expectedSHA256
    self.createParents = createParents
    self.oldText = oldText
    self.newText = newText
    self.expectedReplacements = expectedReplacements
    self.patch = patch
    self.clientRequestID = clientRequestID
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case kind
    case relativePath = "relative_path"
    case mode
    case content
    case expectedSHA256 = "expected_sha256"
    case createParents = "create_parents"
    case oldText = "old_text"
    case newText = "new_text"
    case expectedReplacements = "expected_replacements"
    case patch
    case clientRequestID = "client_request_id"
  }
}

public struct MCPDirectApplyMutationRequest: Codable, Equatable, Sendable {
  public let operationID: String
  public let clientRequestID: String?

  public init(operationID: String, clientRequestID: String? = nil) {
    self.operationID = operationID
    self.clientRequestID = clientRequestID
  }

  private enum CodingKeys: String, CodingKey {
    case operationID = "operation_id"
    case clientRequestID = "client_request_id"
  }
}

public struct MCPDirectUndoMutationRequest: Codable, Equatable, Sendable {
  public let operationID: String
  public let clientRequestID: String?

  public init(operationID: String, clientRequestID: String? = nil) {
    self.operationID = operationID
    self.clientRequestID = clientRequestID
  }

  private enum CodingKeys: String, CodingKey {
    case operationID = "operation_id"
    case clientRequestID = "client_request_id"
  }
}

public struct MCPDirectMutationRevision: Codable, Equatable, Sendable {
  public let sha256: String
  public let byteCount: Int

  public init(sha256: String, byteCount: Int) {
    self.sha256 = sha256
    self.byteCount = byteCount
  }

  private enum CodingKeys: String, CodingKey {
    case sha256
    case byteCount = "byte_count"
  }
}

public struct MCPDirectMutationFile: Codable, Equatable, Sendable {
  public let relativePath: String
  public let beforeRevision: MCPDirectMutationRevision?
  public let afterRevision: MCPDirectMutationRevision
  public let boundedDiff: MCPBoundedDiff

  public init(
    relativePath: String,
    beforeRevision: MCPDirectMutationRevision?,
    afterRevision: MCPDirectMutationRevision,
    boundedDiff: MCPBoundedDiff
  ) {
    self.relativePath = relativePath
    self.beforeRevision = beforeRevision
    self.afterRevision = afterRevision
    self.boundedDiff = boundedDiff
  }

  private enum CodingKeys: String, CodingKey {
    case relativePath = "relative_path"
    case beforeRevision = "before_revision"
    case afterRevision = "after_revision"
    case boundedDiff = "bounded_diff"
  }
}

public struct MCPDirectMutationPreview: Codable, Equatable, Sendable {
  public let operationID: String
  public let projectID: String
  public let kind: String
  public let changedFiles: [MCPDirectMutationFile]
  public let preparedAt: String

  public init(
    operationID: String,
    projectID: String,
    kind: String,
    changedFiles: [MCPDirectMutationFile],
    preparedAt: String
  ) {
    self.operationID = operationID
    self.projectID = projectID
    self.kind = kind
    self.changedFiles = changedFiles
    self.preparedAt = preparedAt
  }

  private enum CodingKeys: String, CodingKey {
    case operationID = "operation_id"
    case projectID = "project_id"
    case kind
    case changedFiles = "changed_files"
    case preparedAt = "prepared_at"
  }
}

public struct MCPDirectMutationReceipt: Codable, Equatable, Sendable {
  public let operationID: String
  public let projectID: String
  public let kind: String
  public let status: String
  public let changedFiles: [MCPDirectMutationFile]
  public let timestamp: String

  public init(
    operationID: String,
    projectID: String,
    kind: String,
    status: String,
    changedFiles: [MCPDirectMutationFile],
    timestamp: String
  ) {
    self.operationID = operationID
    self.projectID = projectID
    self.kind = kind
    self.status = status
    self.changedFiles = changedFiles
    self.timestamp = timestamp
  }

  private enum CodingKeys: String, CodingKey {
    case operationID = "operation_id"
    case projectID = "project_id"
    case kind
    case status
    case changedFiles = "changed_files"
    case timestamp
  }
}
