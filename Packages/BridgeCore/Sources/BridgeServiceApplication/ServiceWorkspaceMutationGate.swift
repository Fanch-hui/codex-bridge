import BridgeDomain
import BridgeMCP
import BridgeServiceCore
import Foundation

private final class WorkspaceRecoveryLookup: @unchecked Sendable {
  private let lock = NSLock()
  private var lookup: @Sendable (ProjectID) async throws -> [String] = { _ in [] }

  func set(_ value: @escaping @Sendable (ProjectID) async throws -> [String]) {
    lock.withLock { lookup = value }
  }

  func value(for projectID: ProjectID) async throws -> [String] {
    let current = lock.withLock { lookup }
    return try await current(projectID)
  }
}

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
  private nonisolated let recoveryLookup = WorkspaceRecoveryLookup()
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
  private enum ServiceShutdownState {
    case checking, committed
  }

  private var serviceShutdown: ServiceShutdownState?
  private let appUpdateLeaseDuration: TimeInterval
  public nonisolated let changes: ServiceStateChangeHub

  public init(appUpdateLeaseDuration: TimeInterval = 60) {
    self.appUpdateLeaseDuration = max(1, appUpdateLeaseDuration)
    self.changes = ServiceStateChangeHub()
  }

  public nonisolated func setRecoveryLookup(
    _ lookup: @escaping @Sendable (ProjectID) async throws -> [String]
  ) {
    recoveryLookup.set(lookup)
  }

  public nonisolated func workspaceRecoveryChanged() {
    changes.publish()
  }

  @discardableResult
  public func beginTaskAdmission() throws -> String {
    expireAppUpdateIfNeeded()
    guard appUpdateLeaseExpiresAt == nil, serviceShutdown == nil else {
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
    guard serviceShutdown == nil else { return false }
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

  public func appUpdateWaitingReason() -> String? {
    let writes =
      directReservations.values.filter {
        if case .directCommand = $0.owner { return false }
        return true
      }.count + codexAdmissions.values.reduce(0) { $0 + $1.count }
    var reasons: [String] = []
    if writes > 0 { reasons.append("\(writes) 项工作区写操作") }
    if !taskAdmissions.isEmpty { reasons.append("\(taskAdmissions.count) 个任务正在提交") }
    if serviceShutdown != nil { reasons.append("后台服务正在关闭") }
    return reasons.isEmpty ? nil : reasons.joined(separator: "、")
  }

  public func appUpdatePrepared() -> Bool {
    expireAppUpdateIfNeeded()
    return appUpdateLeaseExpiresAt != nil
  }

  public func beginIdleServiceShutdown() -> Bool {
    guard serviceShutdown == nil, beginAppUpdate() else { return false }
    serviceShutdown = .checking
    return true
  }

  public func commitServiceShutdown() {
    serviceShutdown = .committed
  }

  public func cancelIdleServiceShutdown() {
    guard serviceShutdown == .checking else { return }
    serviceShutdown = nil
    cancelAppUpdate()
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
    if let recovery = try await recoveryLookup.value(for: projectID).first {
      return .direct(owner: "workspace_recovery", operationID: recovery)
    }
    return nil
  }

  public func acquireDirectLease(
    projectID: ProjectID,
    owner: ServiceWorkspaceOwner,
    activeCodexWriteTask: @Sendable () async throws -> ServiceTaskRecord?,
    activeEmbeddedDSHSession: @Sendable () async throws -> String? = { nil },
    permittingRecoveryID: String? = nil
  ) async throws -> DirectWorkspaceLease {
    expireAppUpdateIfNeeded()
    guard appUpdateLeaseExpiresAt == nil, serviceShutdown == nil else {
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
      let recoveries = try await recoveryLookup.value(for: projectID)
      if let recovery = recoveries.first,
        permittingRecoveryID.map({ !recoveries.contains($0) }) ?? true
      {
        throw ProjectWorkspaceBusyError.busy(
          .direct(owner: "workspace_recovery", operationID: recovery))
      }
      if let task = try await activeCodexWriteTask() {
        removeDirectReservation(projectID: projectID, token: token)
        throw ProjectWorkspaceBusyError.busy(.codex(taskID: task.id.rawValue))
      }
      if let sessionID = try await activeEmbeddedDSHSession() {
        removeDirectReservation(projectID: projectID, token: token)
        throw ProjectWorkspaceBusyError.busy(.direct(owner: "embedded_dsh", operationID: sessionID))
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
    guard appUpdateLeaseExpiresAt == nil, serviceShutdown == nil else {
      throw ProjectWorkspaceBusyError.busy(.direct(owner: "app_update"))
    }
    if let direct = directReservations[projectID] {
      throw ProjectWorkspaceBusyError.busy(direct.owner.busyDetail)
    }
    let token = UUID().uuidString
    codexAdmissions[projectID, default: []].insert(token)
    do {
      if let recovery = try await recoveryLookup.value(for: projectID).first {
        throw ProjectWorkspaceBusyError.busy(
          .direct(owner: "workspace_recovery", operationID: recovery))
      }
    } catch {
      endCodexAdmission(projectID: projectID, token: token)
      throw error
    }
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
    serviceShutdown = nil
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
