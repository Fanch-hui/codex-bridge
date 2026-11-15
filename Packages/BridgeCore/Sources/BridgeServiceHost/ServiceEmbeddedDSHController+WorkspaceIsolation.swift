import BridgeAgentCore
import BridgeCodexRPC
import BridgeDomain
import BridgeFiles
import BridgeProcess
import BridgeSecurity
import BridgeServiceCore
import Foundation

/// Where a subagent runs. Deciding is split from activating so the slow part (copying the project
/// and probing the provider inside the copy) can run without the controller-wide `inputGate`.
enum SubagentWorkspacePlan: Sendable {
  /// The child already has a stored mode, which the short gated path validates.
  case existing
  case shared(reason: String?)
  /// A copy that is prepared but not activated yet; `commitSubagentWorkspace` activates it.
  case isolated(id: String, reason: String?)
}

struct SubagentWorkspaceOutcome: Sendable {
  let mode: String
  var synchronizedPaths: [String] = []
  var repairPaths: [String] = []
}

extension ServiceEmbeddedDSHController {
  static let isolationUnsupportedReason = "该执行器尚未启用进程写入隔离。"
  static let isolationUnverifiedReason = "此 Agent 尚未提供可验证的进程隔离。"
  static let projectChangedWhileCopyingReason = "项目在复制期间持续变化，本次改用共享目录。"
  private static let copyAttempts = 3

  /// Decides for a new child, and copies the project only when isolation cannot be ruled out
  /// without a copy. Takes no gate itself; the copy is the slow step.
  func planNewSubagentWorkspace(
    id: String, projectID: ProjectID, providerID: String, installationID: String?,
    permissionMode: ServicePermissionMode, continuation: Bool
  ) async throws -> SubagentWorkspacePlan {
    if let shared = sharedPlanWithoutCopy(
      providerID: providerID, installationID: installationID, permissionMode: permissionMode,
      continuation: continuation)
    {
      return shared
    }
    return try await prepareIsolatedSubagentCopy(
      id: id, projectRoot: registeredProjectRoot(projectID), providerID: providerID,
      installationID: installationID)
  }

  /// Nil means isolation is possible and only a copy can tell. Everything else is known without
  /// one, so no project is copied just to be thrown away.
  private func sharedPlanWithoutCopy(
    providerID: String, installationID: String?, permissionMode: ServicePermissionMode,
    continuation: Bool
  ) -> SubagentWorkspacePlan? {
    let isCodex = providerID == "codex"
    if continuation { return .shared(reason: "此会话沿用原来的项目目录。") }
    if isCodex, !CodexIsolatedLaunch.supportsFileOnlyExecution {
      return .shared(reason: "当前 Codex 文件操作依赖命令进程，使用共享目录串行执行。")
    }
    guard permissionMode == .full else { return .shared(reason: nil) }
    guard isCodex ? CodexIsolatedLaunch.isAvailable : WorkspaceProcessIsolation.isAvailable else {
      return .shared(reason: "当前平台的隔离检查未通过。")
    }
    guard !isCodex else { return nil }
    guard installationID != nil else { return .shared(reason: Self.isolationUnverifiedReason) }
    return externalWorkspaceSupport(providerID).map { .shared(reason: $0) }
  }

  /// Copies the project, then asks the provider whether it can run inside the copy. A copy that
  /// turns out unusable is discarded here; a usable one stays unactivated until the gated commit.
  func prepareIsolatedSubagentCopy(
    id: String, projectRoot: RegisteredRoot, providerID: String, installationID: String?
  ) async throws -> SubagentWorkspacePlan {
    let snapshot: AgentWorkspaceSnapshot
    do {
      snapshot = try await copyProjectForSubagent(id: id, projectRoot: projectRoot)
    } catch AgentWorkspaceError.revisionConflict(_) {
      return .shared(reason: Self.projectChangedWhileCopyingReason)
    } catch let error as AgentWorkspaceError {
      guard let reason = Self.isolationFallbackReason(for: error) else { throw error }
      return .shared(reason: reason)
    }
    do {
      let readiness = try await isolationReadiness(
        providerID: providerID, installationID: installationID, snapshot: snapshot)
      guard readiness.ready else {
        await discardUnstartedWorkspace(id: id)
        return .shared(reason: readiness.reason)
      }
      return .isolated(id: id, reason: readiness.reason)
    } catch {
      await discardUnstartedWorkspace(id: id)
      throw error
    }
  }

  /// Files changing while they are copied fail the copy. The store already removed the failed
  /// copy, so a bounded number of retries rides out a burst of edits.
  private func copyProjectForSubagent(id: String, projectRoot: RegisteredRoot) async throws
    -> AgentWorkspaceSnapshot
  {
    var attempt = 1
    while true {
      do {
        return try await prepareWorkspaceReclaimingIfFull(id: id, projectRoot: projectRoot)
      } catch AgentWorkspaceError.revisionConflict(_) where attempt < Self.copyAttempts {
        attempt += 1
        try await Task.sleep(for: .milliseconds(300))
      }
    }
  }

  private func isolationReadiness(
    providerID: String, installationID: String?, snapshot: AgentWorkspaceSnapshot
  ) async throws -> (ready: Bool, reason: String?) {
    if providerID == "codex" { return try await isolatedWorkspaceIsReady(snapshot) }
    guard let installationID else { return (false, Self.isolationUnverifiedReason) }
    let result = try await externalWorkspaceIsReady(
      providerID: providerID, installationID: installationID, snapshot: snapshot)
    return (result.ready, result.reason)
  }

  /// Activates a prepared copy and stores the mode. Runs under `inputGate`, where the short
  /// checks that may have changed since the plan was made are done by the caller.
  func commitSubagentWorkspace(
    _ plan: SubagentWorkspacePlan, rootID: String, childID: String, projectID: ProjectID,
    providerID: String, continuation: Bool
  ) async throws -> SubagentWorkspaceOutcome {
    let id = Self.workspaceID(rootID: rootID, childID: childID)
    switch plan {
    case .existing:
      guard let stored = try await store.setting(key: Self.workspaceModeKey(id)) else {
        throw ServiceStoreError.invalidArgument("embedded_dsh.workspace_mode")
      }
      return try await existingSubagentWorkspace(
        mode: stored.value, rootID: rootID, childID: childID, projectID: projectID,
        providerID: providerID, continuation: continuation)
    case .shared(let reason):
      try await saveSubagentWorkspaceMode("shared", reason: reason, id: id)
      return SubagentWorkspaceOutcome(mode: "shared")
    case .isolated(let isolatedID, let reason):
      try await workspaces.markStarted(id: isolatedID)
      try await saveSubagentWorkspaceMode("isolated", reason: reason, id: id)
      return SubagentWorkspaceOutcome(mode: "isolated")
    }
  }

  private func saveSubagentWorkspaceMode(_ mode: String, reason: String?, id: String) async throws {
    let modeKey = Self.workspaceModeKey(id)
    let reasonKey = Self.workspaceReasonKey(id)
    try await store.updateSettingsAtomically(keys: [modeKey, reasonKey], updatedAt: Date()) { _ in
      [modeKey: mode, reasonKey: reason ?? ""]
    }
  }

  /// Removes a prepared copy that was never activated; an activated one is kept by the store.
  /// Detached, because the cleanup walks the copy with cancellation checks and must still finish
  /// for a request that was cancelled.
  func discardUnstartedWorkspace(id: String) async {
    let workspaces = workspaces
    await Task.detached { _ = try? await workspaces.discardPrepared(id: id) }.value
  }

  func discardUnstartedWorkspace(_ plan: SubagentWorkspacePlan) async {
    guard case .isolated(let id, _) = plan else { return }
    await discardUnstartedWorkspace(id: id)
  }
}
