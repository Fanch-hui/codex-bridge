import BridgeDomain
import BridgeProjects
import BridgeSecurity
import Foundation

extension RestrictedProjectFileService {
  public func listDirectory(_ request: ProjectDirectoryRequest) async throws
    -> ProjectDirectoryResult
  {
    let project = try await requireReadableProjectForDirectory(request.projectID)
    guard request.depth <= limits.maximumDirectoryDepth else {
      throw ProjectFileError.directoryDepthExceeded
    }
    let policy = ProjectFilePolicy(forbiddenPatterns: project.forbiddenPatterns)
    let scope = try validatedDirectory(request.relativeDirectory, project: project, policy: policy)
    let entries = try await enumerateDirectory(
      project: project,
      scope: scope,
      depth: request.depth,
      kind: request.kind,
      policy: policy
    )
    let signature = DirectoryCursor.signature(
      projectID: request.projectID,
      root: project.primaryRoot,
      scope: scope,
      depth: request.depth,
      kind: request.kind,
      entries: entries
    )
    let start = try DirectoryCursor.decode(request.cursor, signature: signature)
    guard start <= entries.count else { throw ProjectFileError.invalidCursor }
    let end = min(start + request.limit, entries.count)
    var visible = Array(entries[start..<end])
    while true {
      let continuation =
        start + visible.count < entries.count
        ? DirectoryCursor.encode(start + visible.count, signature: signature) : nil
      let result = ProjectDirectoryResult(
        relativeDirectory: scope?.value,
        entries: visible,
        nextCursor: continuation
      )
      if try encodedSize(result) <= limits.maximumResponseBytes {
        guard !visible.isEmpty || entries.isEmpty else {
          throw ProjectFileError.responseLimitExceeded
        }
        return result
      }
      guard !visible.isEmpty else { throw ProjectFileError.responseLimitExceeded }
      visible.removeLast()
    }
  }

  public func batchRead(_ request: ProjectFileBatchReadRequest) async throws
    -> ProjectFileBatchReadResult
  {
    guard request.files.count <= limits.maximumBatchFiles else {
      throw ProjectFileError.invalidBatchRequest
    }
    var items: [ProjectFileBatchReadItem] = []
    var truncated = false
    for file in request.files {
      try Task.checkCancellation()
      let item: ProjectFileBatchReadItem
      do {
        item = ProjectFileBatchReadItem(
          relativePath: file.relativePath,
          result: try await read(file),
          error: nil
        )
      } catch {
        item = ProjectFileBatchReadItem(
          relativePath: file.relativePath,
          result: nil,
          error: error.localizedDescription
        )
      }
      let candidate = items + [item]
      let result = ProjectFileBatchReadResult(
        items: candidate,
        truncated: false,
        omittedCount: request.files.count - candidate.count
      )
      if try encodedSize(result) <= limits.maximumBatchResponseBytes {
        items.append(item)
      } else {
        truncated = true
        break
      }
    }
    return ProjectFileBatchReadResult(
      items: items,
      truncated: truncated || items.count < request.files.count,
      omittedCount: request.files.count - items.count
    )
  }

  private func requireReadableProjectForDirectory(_ id: ProjectID) async throws -> RegisteredProject
  {
    try await requireReadableProject(id)
  }

  private func validatedDirectory(
    _ value: String?,
    project: RegisteredProject,
    policy: ProjectFilePolicy
  ) throws -> SecureRelativePath? {
    guard let value, !value.isEmpty else { return nil }
    let scope = try SecureRelativePath(value)
    guard policy.allows(scope) else { throw ProjectFileError.forbiddenPath }
    do {
      _ = try ProjectPathResolver(root: project.primaryRoot).resolve(scope)
    } catch PathSecurityError.pathDoesNotExist {
      throw ProjectFileError.pathMissing
    }
    return scope
  }

  private func enumerateDirectory(
    project: RegisteredProject,
    scope: SecureRelativePath?,
    depth: Int,
    kind: ProjectDirectoryKindFilter,
    policy: ProjectFilePolicy
  ) async throws -> [ProjectDirectoryEntry] {
    let root = URL(fileURLWithPath: project.primaryRoot.canonicalPath, isDirectory: true)
    let base = scope.map { root.appending(path: $0.value, directoryHint: .isDirectory) } ?? root
    var entries: [ProjectDirectoryEntry] = []
    try await enumerate(
      at: base,
      relativePath: scope?.value ?? "",
      currentDepth: 0,
      maximumDepth: min(depth, limits.maximumDirectoryDepth),
      kind: kind,
      policy: policy,
      project: project,
      entries: &entries
    )
    return entries.sorted { $0.relativePath < $1.relativePath }
  }

  private func enumerate(
    at directory: URL,
    relativePath: String,
    currentDepth: Int,
    maximumDepth: Int,
    kind: ProjectDirectoryKindFilter,
    policy: ProjectFilePolicy,
    project: RegisteredProject,
    entries: inout [ProjectDirectoryEntry]
  ) async throws {
    guard currentDepth <= maximumDepth else { return }
    let children = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
      options: [.skipsPackageDescendants]
    ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    for child in children {
      try Task.checkCancellation()
      guard entries.count < limits.maximumEnumeratedEntries else {
        throw ProjectFileError.enumerationLimitExceeded
      }
      let childRelative =
        relativePath.isEmpty
        ? child.lastPathComponent
        : "\(relativePath)/\(child.lastPathComponent)"
      guard childRelative.utf8.count <= 4_096 else {
        throw ProjectFileError.pathLengthExceeded
      }
      guard let securePath = try? SecureRelativePath(childRelative), policy.allows(securePath)
      else { continue }
      guard (try? ProjectPathResolver(root: project.primaryRoot).resolve(securePath)) != nil
      else { continue }
      let values = try child.resourceValues(forKeys: [
        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard values.isSymbolicLink != true else { continue }
      let entryKind: ProjectDirectoryEntryKind = values.isDirectory == true ? .directory : .file
      guard kind.includes(entryKind) else {
        if entryKind == .directory, currentDepth < maximumDepth {
          try await enumerate(
            at: child,
            relativePath: childRelative,
            currentDepth: currentDepth + 1,
            maximumDepth: maximumDepth,
            kind: kind,
            policy: policy,
            project: project,
            entries: &entries
          )
        }
        continue
      }
      if entryKind == .directory || values.fileSize.map({ $0 <= limits.maximumFileBytes }) == true {
        entries.append(
          ProjectDirectoryEntry(
            relativePath: childRelative,
            kind: entryKind,
            byteCount: entryKind == .file ? values.fileSize : nil
          )
        )
      }
      if entryKind == .directory, currentDepth < maximumDepth {
        try await enumerate(
          at: child,
          relativePath: childRelative,
          currentDepth: currentDepth + 1,
          maximumDepth: maximumDepth,
          kind: kind,
          policy: policy,
          project: project,
          entries: &entries
        )
      }
      if entries.count.isMultiple(of: 64) { await Task.yield() }
    }
    try project.primaryRoot.validateCurrentIdentity()
  }

  private func encodedSize<T: Encodable>(_ value: T) throws -> Int {
    try JSONEncoder().encode(value).count
  }
}

private enum DirectoryCursor {
  static func signature(
    projectID: ProjectID,
    root: RegisteredRoot,
    scope: SecureRelativePath?,
    depth: Int,
    kind: ProjectDirectoryKindFilter,
    entries: [ProjectDirectoryEntry]
  ) -> String {
    let parts =
      [
        projectID.rawValue,
        String(root.identity.device),
        String(root.identity.inode),
        scope?.value ?? "",
        String(depth),
        kind.rawValue,
      ] + entries.flatMap { [$0.relativePath, $0.kind.rawValue] }
    var hash: UInt64 = 14_695_981_039_346_656_037
    for part in parts {
      for byte in part.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
      }
      hash &*= 1_099_511_628_211
    }
    return String(hash, radix: 16)
  }

  static func encode(_ position: Int, signature: String) -> String {
    "v1.\(signature).\(position)"
  }

  static func decode(_ value: String?, signature: String) throws -> Int {
    guard let value else { return 0 }
    let parts = value.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "v1", parts[1] == Substring(signature),
      let position = Int(parts[2]), position >= 0
    else { throw ProjectFileError.invalidCursor }
    return position
  }
}
