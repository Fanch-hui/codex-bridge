import BridgeDomain
import BridgeFiles
import BridgeMCP
import BridgeSecurity
import Foundation

extension BridgeServiceApplication {
  public func serviceSearchProjectFiles(
    projectID: String,
    query: String,
    relativeDirectory: String?,
    caseSensitive: Bool,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectFileSearchPage {
    try Self.checkDeadline(deadline)
    do {
      let result = try await files.search(
        ProjectFileSearchRequest(
          projectID: ProjectID(rawValue: projectID),
          query: query,
          relativeDirectory: relativeDirectory,
          caseSensitive: caseSensitive,
          limit: limit,
          cursor: cursor
        )
      )
      return MCPProjectFileSearchPage(
        matches: result.matches.map {
          MCPProjectFileSearchMatch(
            relativePath: $0.relativePath,
            lineNumber: $0.lineNumber,
            preview: $0.preview,
            redacted: $0.redacted
          )
        },
        nextCursor: result.nextCursor,
        skippedFileCount: result.skippedFileCount
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.publicFileError(error)
    }
  }

  public func serviceReadProjectFile(
    projectID: String,
    relativePath: String,
    startLine: Int,
    lineCount: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectFileReadPage {
    try Self.checkDeadline(deadline)
    do {
      let result = try await files.read(
        ProjectFileReadRequest(
          projectID: ProjectID(rawValue: projectID),
          relativePath: relativePath,
          lineRange: try FileLineRange(startLine: startLine, lineCount: lineCount)
        )
      )
      return MCPProjectFileReadPage(
        relativePath: result.relativePath,
        startLine: result.startLine,
        endLine: result.endLine,
        content: result.content,
        redactedLineCount: result.redactedLineCount,
        truncated: result.truncated,
        nextStartLine: result.nextStartLine,
        sha256: result.sha256,
        byteCount: result.byteCount
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.publicFileError(error)
    }
  }

  public func serviceListProjectDirectory(
    projectID: String,
    relativeDirectory: String?,
    depth: Int,
    kind: String,
    cursor: String?,
    limit: Int,
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectDirectoryPage {
    try Self.checkDeadline(deadline)
    guard let filter = ProjectDirectoryKindFilter(rawValue: kind) else {
      throw BridgeMCPQueryError.contractRejected
    }
    do {
      let result = try await files.listDirectory(
        try ProjectDirectoryRequest(
          projectID: ProjectID(rawValue: projectID),
          relativeDirectory: relativeDirectory,
          depth: depth,
          kind: filter,
          limit: limit,
          cursor: cursor
        )
      )
      return MCPProjectDirectoryPage(
        relativeDirectory: result.relativeDirectory,
        entries: result.entries.map {
          MCPProjectDirectoryEntry(
            relativePath: $0.relativePath,
            kind: $0.kind.rawValue,
            byteCount: $0.byteCount
          )
        },
        nextCursor: result.nextCursor
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.publicFileError(error)
    }
  }

  public func serviceBatchReadProjectFiles(
    projectID: String,
    files fileInputs: [MCPProjectFileBatchReadItemRequest],
    deadline: ContinuousClock.Instant
  ) async throws -> MCPProjectFileBatchPage {
    try Self.checkDeadline(deadline)
    do {
      let requests = try fileInputs.map { input in
        ProjectFileReadRequest(
          projectID: ProjectID(rawValue: projectID),
          relativePath: input.relativePath,
          lineRange: try FileLineRange(
            startLine: input.startLine ?? 1,
            lineCount: min(input.lineCount ?? 10_000, FileLineRange.maximumLineCount)
          )
        )
      }
      let result = try await files.batchRead(try ProjectFileBatchReadRequest(files: requests))
      return MCPProjectFileBatchPage(
        items: result.items.map { item in
          MCPProjectFileBatchItem(
            relativePath: item.relativePath,
            result: item.result.map(Self.mcpFileReadPage),
            error: item.error
          )
        },
        truncated: result.truncated,
        omittedCount: result.omittedCount
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw Self.publicFileError(error)
    }
  }

  private static func mcpFileReadPage(_ result: ProjectFileReadResult) -> MCPProjectFileReadPage {
    MCPProjectFileReadPage(
      relativePath: result.relativePath,
      startLine: result.startLine,
      endLine: result.endLine,
      content: result.content,
      redactedLineCount: result.redactedLineCount,
      truncated: result.truncated,
      nextStartLine: result.nextStartLine,
      sha256: result.sha256,
      byteCount: result.byteCount
    )
  }
}
