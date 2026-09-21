import BridgeDomain
import BridgeSecurity
import Foundation

extension RestrictedProjectMutationService {
  func prepareWrite(_ request: ProjectWriteRequest) async throws -> PreparedProjectMutation {
    let project = try await requireProject(request.projectID)
    let path = try securePath(request.relativePath)
    let data = try textContent(request.content)
    let resolver = ProjectPathResolver(root: project.primaryRoot)
    let policy = ProjectFilePolicy(forbiddenPatterns: project.forbiddenPatterns)
    guard policy.allows(path) else { throw ProjectMutationError.forbiddenPath }
    let beforeContent = try mutationErrors {
      try writer.readContent(relativePath: path, through: resolver)
    }
    let beforeRevision = beforeContent.map { SecureFileRevision.digest(of: $0) }
    switch request.mode {
    case .create:
      guard beforeContent == nil else { throw ProjectMutationError.pathExists }
    case .replace:
      guard beforeContent != nil else { throw ProjectMutationError.pathMissing }
      guard request.expectedSHA256 == nil || request.expectedSHA256 == beforeRevision?.sha256 else {
        throw ProjectMutationError.revisionConflict
      }
    }
    let guarded = ProjectWriteRequest(
      projectID: request.projectID,
      relativePath: path.value,
      mode: request.mode,
      content: request.content,
      expectedSHA256: beforeRevision?.sha256,
      createParents: request.createParents
    )
    return PreparedProjectMutation(
      projectID: request.projectID,
      request: .write(guarded),
      changedFiles: [makeChange(path: path.value, before: beforeContent, after: data)]
    )
  }

  func prepareEdit(_ request: ProjectEditRequest) async throws -> PreparedProjectMutation {
    let project = try await requireProject(request.projectID)
    guard !request.oldText.isEmpty, !request.newText.isEmpty, request.expectedReplacements >= 1
    else {
      throw ProjectMutationError.invalidRequest
    }
    let path = try securePath(request.relativePath)
    let resolver = ProjectPathResolver(root: project.primaryRoot)
    let policy = ProjectFilePolicy(forbiddenPatterns: project.forbiddenPatterns)
    guard policy.allows(path) else { throw ProjectMutationError.forbiddenPath }
    guard
      let raw = try mutationErrors({ try writer.readContent(relativePath: path, through: resolver) }
      )
    else {
      throw ProjectMutationError.pathMissing
    }
    guard let current = String(data: raw, encoding: .utf8) else {
      throw ProjectMutationError.binaryContent
    }
    let revision = SecureFileRevision.digest(of: raw)
    guard revision.sha256 == request.expectedSHA256 else {
      throw ProjectMutationError.revisionConflictWithContext(
        relativePath: path.value,
        currentSHA256: revision.sha256,
        boundedDiff: BoundedDiffMaker.make(old: "", new: current)
      )
    }
    guard preparedCountOccurrences(of: request.oldText, in: current) == request.expectedReplacements
    else {
      throw ProjectMutationError.revisionConflictWithContext(
        relativePath: path.value,
        currentSHA256: revision.sha256,
        boundedDiff: BoundedDiffMaker.make(old: "", new: current)
      )
    }
    let updated = current.replacingOccurrences(of: request.oldText, with: request.newText)
    let guarded = ProjectEditRequest(
      projectID: request.projectID,
      relativePath: path.value,
      expectedSHA256: revision.sha256,
      oldText: request.oldText,
      newText: request.newText,
      expectedReplacements: request.expectedReplacements
    )
    return PreparedProjectMutation(
      projectID: request.projectID,
      request: .edit(guarded),
      changedFiles: [makeChange(path: path.value, before: raw, after: try textContent(updated))]
    )
  }

  func preparePatch(_ request: ProjectApplyPatchRequest) async throws -> PreparedProjectMutation {
    let project = try await requireProject(request.projectID)
    guard !request.operations.isEmpty else { throw ProjectMutationError.invalidRequest }
    let resolver = ProjectPathResolver(root: project.primaryRoot)
    let policy = ProjectFilePolicy(forbiddenPatterns: project.forbiddenPatterns)
    var guarded: [ProjectPatchFileOperation] = []
    var changes: [PreparedProjectMutationFile] = []
    var paths = Set<String>()
    for operation in request.operations {
      let path = try securePath(operation.relativePath)
      guard paths.insert(path.value).inserted else { throw ProjectMutationError.invalidPatchSyntax }
      guard policy.allows(path) else { throw ProjectMutationError.forbiddenPath }
      switch operation.action {
      case "add":
        let existing = try mutationErrors {
          try writer.readContent(relativePath: path, through: resolver)
        }
        guard existing == nil else { throw ProjectMutationError.pathExists }
        let additions = operation.hunks.flatMap(\.additions)
        let content = additions.joined(separator: "\n") + (additions.isEmpty ? "" : "\n")
        let data = try textContent(content)
        guarded.append(operation)
        changes.append(makeChange(path: path.value, before: nil, after: data))
      case "update":
        guard
          let raw = try mutationErrors({
            try writer.readContent(relativePath: path, through: resolver)
          })
        else {
          throw ProjectMutationError.pathMissing
        }
        guard let current = String(data: raw, encoding: .utf8) else {
          throw ProjectMutationError.binaryContent
        }
        let revision = SecureFileRevision.digest(of: raw)
        guard operation.expectedSHA256 == nil || operation.expectedSHA256 == revision.sha256 else {
          throw ProjectMutationError.revisionConflictWithContext(
            relativePath: path.value,
            currentSHA256: revision.sha256,
            boundedDiff: BoundedDiffMaker.make(old: "", new: current)
          )
        }
        let updated = try ProjectPatchApplier.apply(hunks: operation.hunks, to: current)
        let data = try textContent(updated)
        guarded.append(
          ProjectPatchFileOperation(
            action: operation.action,
            relativePath: path.value,
            expectedSHA256: revision.sha256,
            hunks: operation.hunks
          )
        )
        changes.append(makeChange(path: path.value, before: raw, after: data))
      default:
        throw ProjectMutationError.invalidPatchSyntax
      }
    }
    return PreparedProjectMutation(
      projectID: request.projectID,
      request: .patch(ProjectApplyPatchRequest(projectID: request.projectID, operations: guarded)),
      changedFiles: changes
    )
  }

  func makeChange(path: String, before: Data?, after: Data) -> PreparedProjectMutationFile {
    let beforeRevision = before.map { SecureFileRevision.digest(of: $0) }
    let afterRevision = SecureFileRevision.digest(of: after)
    return PreparedProjectMutationFile(
      relativePath: path,
      beforeRevision: beforeRevision.map {
        FileRevision(sha256: $0.sha256, byteCount: $0.byteCount)
      },
      afterRevision: FileRevision(sha256: afterRevision.sha256, byteCount: afterRevision.byteCount),
      beforeContent: before,
      afterContent: after,
      boundedDiff: BoundedDiffMaker.make(
        old: before.map { String(decoding: $0, as: UTF8.self) } ?? "",
        new: String(decoding: after, as: UTF8.self)
      )
    )
  }

  func preparedCountOccurrences(of needle: String, in haystack: String) -> Int {
    var count = 0
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let range = haystack.range(of: needle, options: .literal, range: searchRange) {
      count += 1
      searchRange = range.upperBound..<haystack.endIndex
    }
    return count
  }
}
