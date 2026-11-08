import BridgeProjects
import BridgeSecurity
import Foundation

public enum AgentWorkspaceError: Error, Equatable, Sendable {
  case invalidIdentifier
  case invalidStorage
  case projectMismatch
  case workspaceUnavailable
  case workspaceBusy
  case unsupportedEntry(String)
  case resourceLimit
  case gitUnavailable
  case mergeConflict([String])
  case invalidResolution(String)
  case revisionConflict(String)
  case recoveryRequired([String])
}

public struct AgentWorkspaceSnapshot: Equatable, Sendable {
  public let id: String
  public let projectRoot: RegisteredRoot
  public let workspaceRoot: RegisteredRoot
  public let runtimeRoot: RegisteredRoot
  public let revision: Int
}

public struct AgentWorkspaceMergePlan: Sendable {
  public let id: String
  public let revision: Int
  public let changedPaths: [String]
  public let conflicts: [String]
  let changes: [AgentWorkspaceChange]
}

public struct AgentWorkspaceMergeResult: Equatable, Sendable {
  public let changedPaths: [String]
  public let revision: Int
}

public struct AgentWorkspaceMergeRecovery: Equatable, Sendable {
  public let id: String
  public let projectRoot: RegisteredRoot
  public let changedPaths: [String]
  public let appliedPaths: [String]
  public let pendingPaths: [String]
  public let divergedPaths: [String]
  public let isRollingBack: Bool
  public let failureReason: String?
  public let inspectionError: String?
}

public struct AgentWorkspaceRecoveryFailure: Error, Sendable {
  public let paths: [String]
  public let failureReason: String
  public let journalFailureReason: String?
}

public struct AgentWorkspaceConflictResolution: Equatable, Sendable {
  public let relativePath: String
  public let expectedSHA256: String?

  public init(relativePath: String, expectedSHA256: String?) {
    self.relativePath = relativePath
    self.expectedSHA256 = expectedSHA256
  }
}

public struct AgentWorkspaceResolutionResult: Equatable, Sendable {
  public let resolvedPaths: [String]
  public let revision: Int
  public let archiveID: String
}

struct AgentWorkspacePendingConflict: Codable, Equatable, Sendable {
  let baseline: Data?
  let workspace: Data?
  let workspaceMode: Int?
  let main: Data?
}

struct AgentWorkspaceManifest: Codable, Sendable {
  let version: Int
  let id: String
  let projectRoot: RegisteredRoot
  let baselineIdentity: FileSystemIdentity
  let workspaceIdentity: FileSystemIdentity
  let runtimeIdentity: FileSystemIdentity
  let forbiddenPatterns: [ForbiddenPathPattern]
  var modes: [String: Int]
  var revision: Int
  var pendingConflicts: [String: AgentWorkspacePendingConflict]? = nil
  var repairMarkers: [String: String]? = nil
  var activated: Bool? = nil
  var privateGit: Bool? = nil
  var privateGitIdentity: FileSystemIdentity? = nil
  var privateGitFingerprint: String? = nil
}

struct AgentWorkspaceChange: Codable, Equatable, Sendable {
  let path: String
  let before: Data?
  let after: Data?
  let baseline: Data?
  let workspace: Data?
  let workspaceMode: Int?
  var beforeMode: Int? = nil
}

struct AgentWorkspaceJournal: Codable, Sendable {
  let id: String
  let revision: Int
  let changes: [AgentWorkspaceChange]
  var phase: String? = nil
  var failureReason: String? = nil
}

struct AgentWorkspaceResolutionEntry: Codable, Sendable {
  let path: String
  let conflict: AgentWorkspacePendingConflict
  let selected: Data?
  let selectedMode: Int?
}

struct AgentWorkspaceResolutionJournal: Codable, Sendable {
  let id: String
  let revision: Int
  let archiveID: String
  let entries: [AgentWorkspaceResolutionEntry]
}
