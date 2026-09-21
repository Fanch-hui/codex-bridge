import BridgeDomain
import Foundation

public enum ProjectMutationKind: String, Codable, Equatable, Sendable {
  case write
  case edit
  case patch
}

public enum ProjectMutationRequest: Sendable {
  case write(ProjectWriteRequest)
  case edit(ProjectEditRequest)
  case patch(ProjectApplyPatchRequest)

  public var projectID: ProjectID {
    switch self {
    case .write(let request): return request.projectID
    case .edit(let request): return request.projectID
    case .patch(let request): return request.projectID
    }
  }

  public var kind: ProjectMutationKind {
    switch self {
    case .write: return .write
    case .edit: return .edit
    case .patch: return .patch
    }
  }
}

public struct PreparedProjectMutationFile: Sendable {
  public let relativePath: String
  public let beforeRevision: FileRevision?
  public let afterRevision: FileRevision
  public let beforeContent: Data?
  public let afterContent: Data
  public let boundedDiff: BoundedDiff

  public init(
    relativePath: String,
    beforeRevision: FileRevision?,
    afterRevision: FileRevision,
    beforeContent: Data?,
    afterContent: Data,
    boundedDiff: BoundedDiff
  ) {
    self.relativePath = relativePath
    self.beforeRevision = beforeRevision
    self.afterRevision = afterRevision
    self.beforeContent = beforeContent
    self.afterContent = afterContent
    self.boundedDiff = boundedDiff
  }
}

public struct PreparedProjectMutation: Sendable {
  public let projectID: ProjectID
  public let request: ProjectMutationRequest
  public let changedFiles: [PreparedProjectMutationFile]
  public let preparedAt: Date

  public init(
    projectID: ProjectID,
    request: ProjectMutationRequest,
    changedFiles: [PreparedProjectMutationFile],
    preparedAt: Date = Date()
  ) {
    self.projectID = projectID
    self.request = request
    self.changedFiles = changedFiles
    self.preparedAt = preparedAt
  }

  public var kind: ProjectMutationKind { request.kind }
}

extension RestrictedProjectMutationService {
  public func prepare(_ request: ProjectMutationRequest) async throws -> PreparedProjectMutation {
    switch request {
    case .write(let write): return try await prepareWrite(write)
    case .edit(let edit): return try await prepareEdit(edit)
    case .patch(let patch): return try await preparePatch(patch)
    }
  }

  public func apply(_ prepared: PreparedProjectMutation) async throws -> [ProjectMutationResult] {
    guard prepared.projectID == prepared.request.projectID else {
      throw ProjectMutationError.invalidRequest
    }
    switch prepared.request {
    case .write(let request): return [try await write(request)]
    case .edit(let request): return [try await edit(request)]
    case .patch(let request): return try await applyPatch(request)
    }
  }
}
