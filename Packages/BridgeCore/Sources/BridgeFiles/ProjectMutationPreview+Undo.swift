import BridgeSecurity
import Foundation

extension RestrictedProjectMutationService {
  public func undo(_ prepared: PreparedProjectMutation) async throws -> [ProjectMutationResult] {
    guard prepared.projectID == prepared.request.projectID, !prepared.changedFiles.isEmpty else {
      throw ProjectMutationError.invalidRequest
    }
    let project = try await requireProject(prepared.projectID)
    let resolver = ProjectPathResolver(root: project.primaryRoot)
    let policy = ProjectFilePolicy(forbiddenPatterns: project.forbiddenPatterns)
    let files = try prepared.changedFiles.map {
      change -> (PreparedProjectMutationFile, SecureRelativePath) in
      let path = try securePath(change.relativePath)
      guard policy.allows(path) else { throw ProjectMutationError.forbiddenPath }
      let current = try mutationErrors {
        try writer.revision(relativePath: path, through: resolver)
      }
      guard
        current?.sha256 == change.afterRevision.sha256,
        current?.byteCount == change.afterRevision.byteCount
      else {
        throw ProjectMutationError.revisionConflictWithContext(
          relativePath: change.relativePath,
          currentSHA256: current?.sha256 ?? "",
          boundedDiff: change.boundedDiff
        )
      }
      return (change, path)
    }

    var results: [ProjectMutationResult] = []
    do {
      for (change, path) in files.reversed() {
        if let beforeContent = change.beforeContent {
          let result = try mutationErrors {
            try writer.write(
              relativePath: path,
              through: resolver,
              mode: .replace,
              content: beforeContent,
              expectedSHA256: change.afterRevision.sha256,
              createParents: false
            )
          }
          results.append(
            ProjectMutationResult(
              relativePath: change.relativePath,
              operation: "undo",
              oldSHA256: change.afterRevision.sha256,
              newSHA256: result.newRevision.sha256,
              byteCount: result.newRevision.byteCount,
              boundedDiff: BoundedDiffMaker.make(
                old: String(decoding: change.afterContent, as: UTF8.self),
                new: String(decoding: beforeContent, as: UTF8.self)
              )
            )
          )
        } else {
          _ = try mutationErrors {
            try directoryMutation.apply(
              action: .deleteFile(expectedSHA256: change.afterRevision.sha256),
              relativePath: path,
              destinationRelativePath: nil,
              through: resolver
            )
          }
          results.append(
            ProjectMutationResult(
              relativePath: change.relativePath,
              operation: "undo",
              oldSHA256: change.afterRevision.sha256,
              newSHA256: nil,
              byteCount: 0,
              boundedDiff: BoundedDiffMaker.make(
                old: String(decoding: change.afterContent, as: UTF8.self), new: ""
              )
            )
          )
        }
      }
      return results
    } catch let error as ProjectMutationError {
      throw error
    } catch {
      throw ProjectMutationError.partialCommit(
        changedFiles: results.map(\.relativePath),
        rollbackStatus: "rollback_not_attempted"
      )
    }
  }
}
