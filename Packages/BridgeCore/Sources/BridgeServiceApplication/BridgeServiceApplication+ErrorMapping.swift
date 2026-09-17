import BridgeAgentCore
import BridgeCodexService
import BridgeDomain
import BridgeFiles
import BridgeMCP
import BridgeProjects
import BridgeSecurity
import BridgeServiceCore
import BridgeSkills
import Foundation

extension BridgeServiceApplication {
  static func publicFileError(_ error: Error) -> BridgeMCPQueryError {
    if let value = error as? ProjectFileError {
      switch value {
      case .unknownProject:
        return .projectNotFound
      case .readNotAllowed, .forbiddenPath:
        return .pathDenied
      case .pathMissing:
        return .pathNotFound
      case .invalidLineRange, .invalidSearchRequest, .invalidCursor:
        return .contractRejected
      case .invalidLimits, .candidateLimitExceeded, .enumerationLimitExceeded,
        .directoryDepthExceeded, .pathLengthExceeded, .lineTooLong,
        .responseLimitExceeded, .unsafeFilesystemState:
        return .unavailable
      }
    }
    if error is PathSecurityError { return .pathDenied }
    return .unavailable
  }

  static func publicSkillError(_ error: Error) -> BridgeMCPQueryError {
    switch error {
    case SkillError.pathEscapeDetected, SkillError.sensitivePath:
      return .pathDenied
    case SkillError.documentTooLarge, SkillError.invalidEncoding, SkillError.invalidManifest,
      SkillError.invalidSkillName, SkillError.tooManySkills:
      return .contractRejected
    case SkillError.documentNotFound:
      return .skillNotFound
    case SkillError.actionNotFound:
      return .skillActionNotFound
    case SkillError.actionNotRunnable:
      return .skillActionNotRunnable
    default:
      return .unavailable
    }
  }

  static func publicStoreError(_ error: ServiceStoreError) -> BridgeMCPQueryError {
    switch error {
    case .unknownProject:
      return .projectNotFound
    case .unknownTask:
      return .taskNotFound
    case .idempotencyConflict, .duplicateTask:
      return .idempotencyConflict
    case .activeWriteTaskExists:
      return .busy
    case .invalidArgument, .invalidTaskTransition, .immutableTaskChanged,
      .duplicateAgentInstallation, .duplicateAgentExecutable, .unknownAgentInstallation:
      return .contractRejected
    case .corruptSchema, .corruptRecord, .unsupportedSchemaVersion,
      .duplicateProject, .duplicateProjectRoot, .storageFailure:
      return .unavailable
    }
  }

  static func publicExecutionError(_ error: Error) -> BridgeMCPQueryError {
    guard let value = error as? ExecutionServiceError else { return .unavailable }
    switch value {
    case .bindingMismatch, .threadMismatch:
      return .turnMismatch
    case .sessionLimitReached, .activeSession:
      return .busy
    case .invalidRequest, .projectPermissionDenied, .approvalExceedsPolicy, .modelUnavailable,
      .effortUnavailable, .serviceTierUnavailable:
      return .contractRejected
    case .projectUnavailable:
      return .projectNotFound
    case .threadUnavailable:
      return .threadNotFound
    case .sessionUnavailable, .sessionEnded, .projectIdentityChanged, .turnUnavailable,
      .turnStartTimedOut, .approvalUnavailable, .protocolViolation, .processUnavailable:
      return .unavailable
    case .conversationPersistenceFailed:
      return .unavailable
    }
  }

  static func publicWorkspaceBusyError(_ error: Error) -> BridgeMCPQueryError {
    guard let value = error as? ProjectWorkspaceBusyError else { return .unavailable }
    switch value {
    case .busy(let detail):
      return .projectBusy(detail)
    }
  }

  static func publicMutationError(_ error: Error) -> BridgeMCPQueryError {
    guard let value = error as? ProjectMutationError else { return .unavailable }
    switch value {
    case .unknownProject:
      return .projectNotFound
    case .readNotAllowed:
      return .pathDenied
    case .writeNotAllowed:
      return .writeNotAllowed
    case .forbiddenPath:
      return .pathForbidden
    case .pathMissing:
      return .pathNotFound
    case .invalidRequest, .pathExists, .contentTooLarge:
      return .contractRejected
    case .revisionConflict:
      return .fileRevisionConflict
    case .revisionConflictWithContext(let relativePath, let currentSHA256, let boundedDiff):
      return .revisionConflict(
        RevisionConflictDetail(
          relativePath: relativePath,
          currentSHA256: currentSHA256,
          changedSinceRevision: true,
          removedLines: boundedDiff.removedLines.map {
            safe($0, maximum: 64 * 1_024)
          },
          addedLines: boundedDiff.addedLines.map {
            safe($0, maximum: 64 * 1_024)
          },
          truncated: boundedDiff.truncated,
          byteCount: boundedDiff.byteCount
        )
      )
    case .pathChanged, .unsupportedHardLink, .unsafeFilesystemState:
      return .pathChanged
    case .binaryContent:
      return .binaryContentUnsupported
    case .invalidPatch, .invalidPatchSyntax:
      return .invalidPatchSyntax
    case .patchContextNotFound:
      return .patchContextNotFound
    case .patchContextNonUnique:
      return .patchContextNonUnique
    case .partialCommit:
      return .unavailable
    case .durabilityUncertain:
      return .durabilityUncertain
    case .notGitRepository:
      return .notGitRepository
    }
  }
}
