import Foundation

public enum MCPFileTransferLimits {
  public static let maximumFileBytes = 16 * 1_024 * 1_024
  public static let maximumChunkBytes = 48 * 1_024
  public static let maximumBase64Bytes = 64 * 1_024
}

public struct MCPFileUploadRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let relativePath: String
  public let byteCount: Int
  public let sha256: String
  public let mode: String
  public let expectedSHA256: String?
  public let createParents: Bool

  public init(
    projectID: String,
    relativePath: String,
    byteCount: Int,
    sha256: String,
    mode: String,
    expectedSHA256: String? = nil,
    createParents: Bool = false
  ) {
    self.projectID = projectID
    self.relativePath = relativePath
    self.byteCount = byteCount
    self.sha256 = sha256
    self.mode = mode
    self.expectedSHA256 = expectedSHA256
    self.createParents = createParents
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case relativePath = "relative_path"
    case byteCount = "byte_count"
    case sha256
    case mode
    case expectedSHA256 = "expected_sha256"
    case createParents = "create_parents"
  }
}

public struct MCPFileTransfer: Codable, Equatable, Sendable {
  public let transferID: String
  public let status: String
  public let receivedBytes: Int
  public let totalBytes: Int
  public let expiresAt: String

  public init(
    transferID: String,
    status: String,
    receivedBytes: Int,
    totalBytes: Int,
    expiresAt: String
  ) {
    self.transferID = transferID
    self.status = status
    self.receivedBytes = receivedBytes
    self.totalBytes = totalBytes
    self.expiresAt = expiresAt
  }

  private enum CodingKeys: String, CodingKey {
    case transferID = "transfer_id"
    case status
    case receivedBytes = "received_bytes"
    case totalBytes = "total_bytes"
    case expiresAt = "expires_at"
  }
}

public struct MCPFileChunkRequest: Codable, Equatable, Sendable {
  public let projectID: String
  public let relativePath: String
  public let offset: Int
  public let length: Int
  public let expectedSHA256: String?

  public init(
    projectID: String,
    relativePath: String,
    offset: Int,
    length: Int,
    expectedSHA256: String? = nil
  ) {
    self.projectID = projectID
    self.relativePath = relativePath
    self.offset = offset
    self.length = length
    self.expectedSHA256 = expectedSHA256
  }

  private enum CodingKeys: String, CodingKey {
    case projectID = "project_id"
    case relativePath = "relative_path"
    case offset
    case length
    case expectedSHA256 = "expected_sha256"
  }
}

public struct MCPFileChunk: Codable, Equatable, Sendable {
  public let relativePath: String
  public let offset: Int
  public let byteCount: Int
  public let totalBytes: Int
  public let sha256: String
  public let dataBase64: String
  public let nextOffset: Int?

  public init(
    relativePath: String,
    offset: Int,
    byteCount: Int,
    totalBytes: Int,
    sha256: String,
    dataBase64: String,
    nextOffset: Int? = nil
  ) {
    self.relativePath = relativePath
    self.offset = offset
    self.byteCount = byteCount
    self.totalBytes = totalBytes
    self.sha256 = sha256
    self.dataBase64 = dataBase64
    self.nextOffset = nextOffset
  }

  private enum CodingKeys: String, CodingKey {
    case relativePath = "relative_path"
    case offset
    case byteCount = "byte_count"
    case totalBytes = "total_bytes"
    case sha256
    case dataBase64 = "data_base64"
    case nextOffset = "next_offset"
  }
}
