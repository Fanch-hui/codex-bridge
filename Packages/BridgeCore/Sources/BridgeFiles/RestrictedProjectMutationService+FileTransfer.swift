import BridgeDomain
import BridgeSecurity
import Foundation

extension RestrictedProjectMutationService {
  public func validateTransferPath(projectID: ProjectID, relativePath: String) async throws {
    let project = try await requireProject(projectID)
    let path = try securePath(relativePath)
    guard ProjectFilePolicy(forbiddenPatterns: project.forbiddenPatterns).allows(path) else {
      throw ProjectMutationError.forbiddenPath
    }
  }

  public func readTransferFile(
    projectID: ProjectID, relativePath: String, maximumBytes: Int
  ) async throws -> Data {
    let project = try await requireProject(projectID)
    let path = try securePath(relativePath)
    guard ProjectFilePolicy(forbiddenPatterns: project.forbiddenPatterns).allows(path) else {
      throw ProjectMutationError.forbiddenPath
    }
    let reader = SecureProjectFileWriter(maximumBytes: maximumBytes)
    guard
      let data = try mutationErrors({
        try reader.readContent(
          relativePath: path, through: ProjectPathResolver(root: project.primaryRoot))
      })
    else { throw ProjectMutationError.pathMissing }
    return data
  }

  public func writeTransferFile(
    projectID: ProjectID, relativePath: String, content: Data, mode: ProjectWriteMode,
    expectedSHA256: String?, createParents: Bool, maximumBytes: Int
  ) async throws -> ProjectMutationResult {
    let project = try await requireProject(projectID)
    let path = try securePath(relativePath)
    guard ProjectFilePolicy(forbiddenPatterns: project.forbiddenPatterns).allows(path) else {
      throw ProjectMutationError.forbiddenPath
    }
    let writer = SecureProjectFileWriter(maximumBytes: maximumBytes)
    let result = try mutationErrors {
      try writer.write(
        relativePath: path, through: ProjectPathResolver(root: project.primaryRoot),
        mode: mode == .create ? .create : .replace, content: content,
        expectedSHA256: expectedSHA256, createParents: createParents,
        allowsBinaryContent: true
      )
    }
    return ProjectMutationResult(
      relativePath: path.value, operation: mode.rawValue,
      oldSHA256: result.oldRevision?.sha256, newSHA256: result.newRevision.sha256,
      byteCount: result.newRevision.byteCount
    )
  }
}
