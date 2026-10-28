import Foundation

public struct MCPChatFileReference: Codable, Equatable, Sendable {
  public let downloadURL: String
  public let fileID: String
  public let mimeType: String?
  public let fileName: String?

  public init(
    downloadURL: String,
    fileID: String,
    mimeType: String? = nil,
    fileName: String? = nil
  ) {
    self.downloadURL = downloadURL
    self.fileID = fileID
    self.mimeType = mimeType
    self.fileName = fileName
  }

  private enum CodingKeys: String, CodingKey {
    case downloadURL = "download_url"
    case fileID = "file_id"
    case mimeType = "mime_type"
    case fileName = "file_name"
  }
}

public struct MCPChatFileImportRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let relativePath: String
  public let file: MCPChatFileReference
  public let mode: String
  public let expectedSHA256: String?
  public let createParents: Bool
  public let clientRequestID: String?

  public init(
    projectID: String,
    relativePath: String,
    file: MCPChatFileReference,
    mode: String,
    expectedSHA256: String? = nil,
    createParents: Bool = false,
    clientRequestID: String? = nil
  ) {
    self.projectID = projectID
    self.relativePath = relativePath
    self.file = file
    self.mode = mode
    self.expectedSHA256 = expectedSHA256
    self.createParents = createParents
    self.clientRequestID = clientRequestID
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case relativePath = "relative_path"
    case file
    case mode
    case expectedSHA256 = "expected_sha256"
    case createParents = "create_parents"
    case clientRequestID = "client_request_id"
  }
}

public struct MCPFileTransferView: Codable, Equatable, Sendable {
  public let projectID: String
  public let projectName: String
  public let relativePath: String?
  public let direction: String
  public let maximumFileBytes: Int
  public let chunkBytes: Int

  public init(
    projectID: String,
    projectName: String,
    relativePath: String? = nil,
    direction: String,
    maximumFileBytes: Int,
    chunkBytes: Int
  ) {
    self.projectID = projectID
    self.projectName = projectName
    self.relativePath = relativePath
    self.direction = direction
    self.maximumFileBytes = maximumFileBytes
    self.chunkBytes = chunkBytes
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case projectName = "project_name"
    case relativePath = "relative_path"
    case direction
    case maximumFileBytes = "maximum_file_bytes"
    case chunkBytes = "chunk_bytes"
  }
}

public enum MCPChatFileImportError: Error, Equatable, Sendable {
  case unsupportedSource
  case expiredSource
  case downloadFailed
  case fileTooLarge
}
