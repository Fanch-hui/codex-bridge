import BridgeDomain
import Foundation

public enum ProjectDirectoryEntryKind: String, Codable, Equatable, Sendable {
  case file
  case directory
}

public enum ProjectDirectoryKindFilter: String, Codable, Equatable, Sendable {
  case all
  case files
  case directories

  func includes(_ kind: ProjectDirectoryEntryKind) -> Bool {
    switch self {
    case .all: true
    case .files: kind == .file
    case .directories: kind == .directory
    }
  }
}

public struct ProjectDirectoryRequest: Equatable, Sendable {
  public let projectID: ProjectID
  public let relativeDirectory: String?
  public let depth: Int
  public let kind: ProjectDirectoryKindFilter
  public let limit: Int
  public let cursor: String?

  public init(
    projectID: ProjectID,
    relativeDirectory: String? = nil,
    depth: Int = 1,
    kind: ProjectDirectoryKindFilter = .all,
    limit: Int = 100,
    cursor: String? = nil
  ) throws {
    guard depth >= 0, limit > 0, cursor?.utf8.count ?? 0 <= 128 else {
      throw ProjectFileError.invalidDirectoryRequest
    }
    self.projectID = projectID
    self.relativeDirectory = relativeDirectory
    self.depth = depth
    self.kind = kind
    self.limit = limit
    self.cursor = cursor
  }
}

public struct ProjectDirectoryEntry: Codable, Equatable, Sendable {
  public let relativePath: String
  public let kind: ProjectDirectoryEntryKind
  public let byteCount: Int?

  public init(
    relativePath: String,
    kind: ProjectDirectoryEntryKind,
    byteCount: Int? = nil
  ) {
    self.relativePath = relativePath
    self.kind = kind
    self.byteCount = byteCount
  }

  private enum CodingKeys: String, CodingKey {
    case relativePath = "relative_path"
    case kind
    case byteCount = "byte_count"
  }
}

public struct ProjectDirectoryResult: Codable, Equatable, Sendable {
  public let relativeDirectory: String?
  public let entries: [ProjectDirectoryEntry]
  public let nextCursor: String?

  public init(
    relativeDirectory: String?,
    entries: [ProjectDirectoryEntry],
    nextCursor: String?
  ) {
    self.relativeDirectory = relativeDirectory
    self.entries = entries
    self.nextCursor = nextCursor
  }

  private enum CodingKeys: String, CodingKey {
    case relativeDirectory = "relative_directory"
    case entries
    case nextCursor = "next_cursor"
  }
}

public struct ProjectFileBatchReadRequest: Equatable, Sendable {
  public let files: [ProjectFileReadRequest]

  public init(files: [ProjectFileReadRequest]) throws {
    guard !files.isEmpty, files.count <= ProjectFileLimits.default.maximumBatchFiles else {
      throw ProjectFileError.invalidBatchRequest
    }
    let projectIDs = Set(files.map { $0.projectID })
    guard projectIDs.count == 1 else { throw ProjectFileError.invalidBatchRequest }
    self.files = files
  }
}

public struct ProjectFileBatchReadItem: Codable, Equatable, Sendable {
  public let relativePath: String
  public let result: ProjectFileReadResult?
  public let error: String?

  public init(
    relativePath: String,
    result: ProjectFileReadResult? = nil,
    error: String? = nil
  ) {
    self.relativePath = relativePath
    self.result = result
    self.error = error
  }

  private enum CodingKeys: String, CodingKey {
    case relativePath = "relative_path"
    case result
    case error
  }
}

public struct ProjectFileBatchReadResult: Codable, Equatable, Sendable {
  public let items: [ProjectFileBatchReadItem]
  public let truncated: Bool
  public let omittedCount: Int

  public init(items: [ProjectFileBatchReadItem], truncated: Bool, omittedCount: Int) {
    self.items = items
    self.truncated = truncated
    self.omittedCount = omittedCount
  }

  private enum CodingKeys: String, CodingKey {
    case items
    case truncated
    case omittedCount = "omitted_count"
  }
}
