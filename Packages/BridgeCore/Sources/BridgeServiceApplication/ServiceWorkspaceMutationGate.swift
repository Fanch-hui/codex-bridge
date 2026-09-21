import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

public enum ServiceWorkspaceOwner: Codable, Equatable, Sendable {
  case directFileOperation(operationID: String)
  case directCommand(sessionID: String)
  case directGitCommit(operationID: String)

  public var ownerCode: String {
    switch self {
    case .directFileOperation:
      "direct_file"
    case .directCommand:
      "direct_command"
    case .directGitCommit:
      "direct_git_commit"
    }
  }

  public var busyDetail: WorkspaceBusyDetail {
    switch self {
    case .directFileOperation(let operationID):
      .direct(owner: "direct_file", operationID: operationID)
    case .directCommand(let sessionID):
      .direct(owner: "direct_command", sessionID: sessionID)
    case .directGitCommit(let operationID):
      .direct(owner: "direct_git_commit", operationID: operationID)
    }
  }
}

public struct DirectWorkspaceLease: Sendable {
  public let projectID: ProjectID
  public let owner: ServiceWorkspaceOwner
  private let gate: ServiceWorkspaceMutationGate
  private let token: String

  init(
    projectID: ProjectID,
    owner: ServiceWorkspaceOwner,
    gate: ServiceWorkspaceMutationGate,
    token: String
  ) {
    self.projectID = projectID
    self.owner = owner
    self.gate = gate
    self.token = token
  }

  public func release() async {
    await gate.releaseDirect(projectID: projectID, owner: owner, token: token)
  }
}

public actor ServiceWorkspaceMutationGate {
  private struct DirectReservation: Sendable {
    let token: String
    let owner: ServiceWorkspaceOwner
  }

  // A direct reservation is installed before the active Codex task lookup
  // awaits. That makes the reservation the single source of truth across the
  // actor re-entry point instead of relying on a check-then-set sequence.
  private var directReservations: [ProjectID: DirectReservation] = [:]
  private var codexAdmissions: [ProjectID: Set<String>] = [:]
  private var taskAdmissions: Set<String> = []
  private var appUpdateLeaseExpiresAt: Date?
  private let appUpdateLeaseDuration: TimeInterval
  public nonisolated let changes: ServiceStateChangeHub

  public init(appUpdateLeaseDuration: TimeInterval = 60) {
    self.appUpdateLeaseDuration = max(1, appUpdateLeaseDuration)
    self.changes = ServiceStateChangeHub()
  }

  @discardableResult
  public func beginTaskAdmission() throws -> String {
    expireAppUpdateIfNeeded()
    guard appUpdateLeaseExpiresAt == nil else {
      throw BridgeMCPQueryError.busy
    }
    let token = UUID().uuidString
    taskAdmissions.insert(token)
    return token
  }

  public func endTaskAdmission(token: String) {
    taskAdmissions.remove(token)
  }

  @discardableResult
  public func beginAppUpdate() -> Bool {
    expireAppUpdateIfNeeded()
    if appUpdateLeaseExpiresAt != nil { return true }
    guard directReservations.isEmpty,
      codexAdmissions.values.allSatisfy(\.isEmpty),
      taskAdmissions.isEmpty
    else {
      return false
    }
    appUpdateLeaseExpiresAt = Date().addingTimeInterval(appUpdateLeaseDuration)
    return true
  }

  public func appUpdatePrepared() -> Bool {
    expireAppUpdateIfNeeded()
    return appUpdateLeaseExpiresAt != nil
  }

  public func cancelAppUpdate() {
    appUpdateLeaseExpiresAt = nil
    changes.publish()
  }

  public func activeDirectOwner(projectID: ProjectID) -> ServiceWorkspaceOwner? {
    expireAppUpdateIfNeeded()
    return directReservations[projectID]?.owner
  }

  public func workspaceBusyDetail(projectID: ProjectID) async throws -> WorkspaceBusyDetail? {
    expireAppUpdateIfNeeded()
    if let direct = directReservations[projectID] {
      return direct.owner.busyDetail
    }
    if !(codexAdmissions[projectID] ?? []).isEmpty {
      return .codexAdmissionPending()
    }
    return nil
  }

  public func acquireDirectLease(
    projectID: ProjectID,
    owner: ServiceWorkspaceOwner,
    activeCodexWriteTask: @Sendable () async throws -> ServiceTaskRecord?
  ) async throws -> DirectWorkspaceLease {
    expireAppUpdateIfNeeded()
    guard appUpdateLeaseExpiresAt == nil else {
      throw ProjectWorkspaceBusyError.busy(.direct(owner: "app_update"))
    }
    if let direct = directReservations[projectID] {
      throw ProjectWorkspaceBusyError.busy(direct.owner.busyDetail)
    }
    if !(codexAdmissions[projectID] ?? []).isEmpty {
      throw ProjectWorkspaceBusyError.busy(.codexAdmissionPending())
    }
    let token = UUID().uuidString
    directReservations[projectID] = DirectReservation(token: token, owner: owner)

    do {
      if let task = try await activeCodexWriteTask() {
        removeDirectReservation(projectID: projectID, token: token)
        throw ProjectWorkspaceBusyError.busy(.codex(taskID: task.id.rawValue))
      }
    } catch {
      removeDirectReservation(projectID: projectID, token: token)
      throw error
    }
    return DirectWorkspaceLease(projectID: projectID, owner: owner, gate: self, token: token)
  }

  @discardableResult
  public func beginCodexAdmission(projectID: ProjectID) async throws -> String {
    expireAppUpdateIfNeeded()
    guard appUpdateLeaseExpiresAt == nil else {
      throw ProjectWorkspaceBusyError.busy(.direct(owner: "app_update"))
    }
    if let direct = directReservations[projectID] {
      throw ProjectWorkspaceBusyError.busy(direct.owner.busyDetail)
    }
    let token = UUID().uuidString
    codexAdmissions[projectID, default: []].insert(token)
    return token
  }

  public func endCodexAdmission(projectID: ProjectID, token: String) {
    guard var tokens = codexAdmissions[projectID], tokens.remove(token) != nil else { return }
    codexAdmissions[projectID] = tokens.isEmpty ? nil : tokens
    changes.publish()
  }

  public func releaseDirect(projectID: ProjectID, owner: ServiceWorkspaceOwner) {
    // Keep this source-compatible fallback for older callers. New leases use
    // their opaque token so a stale lease cannot release a later reservation
    // owned by the same operation value.
    if directReservations[projectID]?.owner == owner {
      directReservations[projectID] = nil
      changes.publish()
    }
  }

  fileprivate func releaseDirect(
    projectID: ProjectID,
    owner: ServiceWorkspaceOwner,
    token: String
  ) {
    guard let reservation = directReservations[projectID],
      reservation.token == token,
      reservation.owner == owner
    else { return }
    directReservations[projectID] = nil
    changes.publish()
  }

  private func removeDirectReservation(projectID: ProjectID, token: String) {
    guard directReservations[projectID]?.token == token else { return }
    directReservations[projectID] = nil
  }

  public func releaseAll() {
    directReservations = [:]
    codexAdmissions = [:]
    taskAdmissions = []
    appUpdateLeaseExpiresAt = nil
    changes.publish()
  }

  private func expireAppUpdateIfNeeded(now: Date = Date()) {
    guard let expiresAt = appUpdateLeaseExpiresAt, expiresAt <= now else { return }
    appUpdateLeaseExpiresAt = nil
    changes.publish()
  }
}

public enum ProjectWorkspaceBusyError: Error, Equatable, Sendable {
  case busy(WorkspaceBusyDetail)
}
