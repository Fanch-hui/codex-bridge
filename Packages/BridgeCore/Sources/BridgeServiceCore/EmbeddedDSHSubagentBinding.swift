import BridgeDomain
import Crypto
import Foundation

public enum EmbeddedDSHRecoveryError: Error, Equatable, Sendable {
  case pendingProcessReconciliation(taskID: TaskID)
}

public enum EmbeddedDSHReconciledOutcome: Equatable, Sendable {
  case completed(resultSummary: String, changedFiles: [String])
  case failed(failureCode: String, summary: String)
  case interrupted(summary: String)
}

public struct EmbeddedDSHExecution: Equatable, Sendable {
  public let sessionID: String
  public let projectID: ProjectID
  public let groupID: String
  public let rootActive: Bool
  public let closing: Bool
  public let permissionMode: ServicePermissionMode
}

/// Trusted host identity for a child created by an embedded DSH session.
public struct EmbeddedDSHSubagentIdentity: Equatable, Sendable {
  public let parentSessionID: String
  public let childID: String

  public init(parentSessionID: String, childID: String) {
    self.parentSessionID = parentSessionID
    self.childID = childID
  }

  public var sourceClientID: String {
    let digest = SHA256.hash(data: Data((parentSessionID + "\0" + childID).utf8))
      .map { String(format: "%02x", $0) }.joined()
    return "embedded.dsh." + digest
  }
}

/// The child identity is stable even when a continuation creates another task.
public struct EmbeddedDSHSubagentBinding: Equatable, Sendable {
  public let parentSessionID: String
  public let childID: String
  public let projectID: ProjectID
  public let providerID: String
  public let installationID: String?
  public let currentTaskID: TaskID?
  public let currentRequestID: String
  public let nativeSessionID: String?
  public let executionModel: String?
  public let executionEffort: String?
  public let currentStatus: ServiceTaskStatus?
  public let createdAt: Date
  public let updatedAt: Date

  public init(
    parentSessionID: String,
    childID: String,
    projectID: ProjectID,
    providerID: String,
    installationID: String?,
    currentTaskID: TaskID?,
    currentRequestID: String,
    nativeSessionID: String?,
    executionModel: String?,
    executionEffort: String?,
    currentStatus: ServiceTaskStatus?,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.parentSessionID = parentSessionID
    self.childID = childID
    self.projectID = projectID
    self.providerID = providerID
    self.installationID = installationID
    self.currentTaskID = currentTaskID
    self.currentRequestID = currentRequestID
    self.nativeSessionID = nativeSessionID
    self.executionModel = executionModel
    self.executionEffort = executionEffort
    self.currentStatus = currentStatus
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct EmbeddedDSHSubagentResult: Equatable, Sendable {
  public let parentSessionID: String
  public let childID: String
  public let requestID: String
  public let taskID: TaskID
  public let status: ServiceTaskStatus
  public let resultSummary: String?
  public let failureCode: String?
}
