import BridgeACP
import BridgeAgentCore
import BridgeCodexRPC
import BridgeDomain
import BridgeEmbeddedDSH
import BridgeFiles
import BridgeMCP
import BridgeProcess
import BridgeSecurity
import BridgeServiceCore
import Crypto
import Foundation

extension ServiceEmbeddedDSHController {
  /// Settles where a subagent runs, every step inline. The staged start (`startSubagent`) is the
  /// production route for new children; this serves continuations, which copy nothing. A new child
  /// needs `inputGate` to be free here, because reclaiming a full store takes it.
  func prepareSubagentWorkspace(
    rootID: String, childID: String, projectID: ProjectID, providerID: String,
    installationID: String?,
    permissionMode: ServicePermissionMode, continuation: Bool
  ) async throws -> SubagentWorkspaceOutcome {
    try await requireNoWorkspaceMergeRecovery(
      permissionMode: permissionMode, projectID: projectID)
    let id = Self.workspaceID(rootID: rootID, childID: childID)
    let plan: SubagentWorkspacePlan
    if try await store.setting(key: Self.workspaceModeKey(id)) != nil {
      plan = .existing
    } else {
      plan = try await planNewSubagentWorkspace(
        id: id, projectID: projectID, providerID: providerID, installationID: installationID,
        permissionMode: permissionMode, continuation: continuation)
    }
    do {
      return try await commitSubagentWorkspace(
        plan, rootID: rootID, childID: childID, projectID: projectID, providerID: providerID,
        continuation: continuation)
    } catch {
      await discardUnstartedWorkspace(plan)
      throw error
    }
  }

  func requireNoWorkspaceMergeRecovery(
    permissionMode: ServicePermissionMode, projectID: ProjectID
  ) async throws {
    guard permissionMode == .full else { return }
    if try await application.pendingWorkspaceMergeRecovery(projectID: projectID) != nil {
      throw ServiceStoreError.invalidArgument("embedded_dsh.workspace_recovery_required")
    }
  }

  /// A child that already has a stored mode keeps it; an isolated one must still be usable.
  func existingSubagentWorkspace(
    mode: String, rootID: String, childID: String, projectID: ProjectID, providerID: String,
    continuation: Bool
  ) async throws -> SubagentWorkspaceOutcome {
    guard mode == "isolated" else {
      guard mode == "shared" else {
        throw ServiceStoreError.invalidArgument("embedded_dsh.workspace_mode")
      }
      return SubagentWorkspaceOutcome(mode: mode)
    }
    let id = Self.workspaceID(rootID: rootID, childID: childID)
    try await requireUsableIsolatedWorkspace(
      id: id, projectID: projectID, providerID: providerID, continuation: continuation)
    if continuation,
      let refreshed = try await refreshedIsolatedWorkspace(id: id, rootID: rootID, childID: childID)
    {
      return refreshed
    }
    return SubagentWorkspaceOutcome(mode: mode)
  }

  private func requireUsableIsolatedWorkspace(
    id: String, projectID: ProjectID, providerID: String, continuation: Bool
  ) async throws {
    let isCodex = providerID == "codex"
    guard isCodex ? CodexIsolatedLaunch.isAvailable : WorkspaceProcessIsolation.isAvailable else {
      throw AgentWorkspaceError.workspaceUnavailable
    }
    guard let snapshot = try await workspaces.snapshot(id: id) else {
      // Merged copies are reclaimed when the managed limit is reached; the work itself is merged.
      throw ServiceStoreError.invalidArgument("embedded_dsh.workspace_reclaimed")
    }
    let root = try await registeredProjectRoot(projectID)
    guard snapshot.projectRoot == root else { throw AgentWorkspaceError.projectMismatch }
  }

  /// Continuing an isolated child first brings its copy up to date with the project, or marks the
  /// conflicts it has to repair. Nil means the copy is used as it is.
  private func refreshedIsolatedWorkspace(id: String, rootID: String, childID: String)
    async throws -> SubagentWorkspaceOutcome?
  {
    let child = try await application.embeddedDSHSubagent(
      parentSessionID: rootID, childID: childID)
    guard let record = try await workspaceRecord(id: id),
      record.taskID == child?.currentTaskID?.rawValue,
      child?.currentStatus?.isTerminal == true,
      !["pending", "failed", "validation_required", "recovery_required"].contains(record.status)
    else { throw ServiceStoreError.invalidArgument("embedded_dsh.workspace_pending") }
    if record.status != "merged",
      record.status == "conflict" || !(record.supersededTaskIDs?.isEmpty ?? true)
    {
      guard (record.supersededTaskIDs?.count ?? 0) < 128 else {
        throw ServiceStoreError.invalidArgument("embedded_dsh.workspace_lineage_capacity")
      }
    }
    if record.status == "conflict" {
      let paths = try await workspaces.prepareConflictRepair(id: id)
      guard !paths.isEmpty else {
        throw ServiceStoreError.invalidArgument("embedded_dsh.workspace_conflict_missing")
      }
      return SubagentWorkspaceOutcome(
        mode: "isolated", repairPaths: Self.workspaceSynchronizationSummary(paths))
    }
    guard record.status == "merged" else { return nil }
    let paths = try await workspaces.synchronize(id: id)
    return SubagentWorkspaceOutcome(
      mode: "isolated", synchronizedPaths: Self.workspaceSynchronizationSummary(paths))
  }

  private static func workspaceSynchronizationSummary(_ paths: [String]) -> [String] {
    var result: [String] = []
    var bytes = 0
    for path in paths {
      guard result.count < 64, bytes + path.utf8.count <= 8_192 else { break }
      result.append(path)
      bytes += path.utf8.count
    }
    return result
  }

  func registeredProjectRoot(_ projectID: ProjectID) async throws -> RegisteredRoot {
    let project = try await registeredProject(projectID.rawValue)
    let root = try RegisteredRoot(
      capturing: URL(fileURLWithPath: project.root.canonicalPath, isDirectory: true))
    guard project.root.matches(root) else {
      throw ServiceStoreError.invalidArgument("project.rootIdentity")
    }
    return root
  }

  func workspaceChanges(
    rootID: String, childID: String, retry: Bool, resolutions input: ACPJSONValue?
  ) async throws -> ACPJSONValue {
    let id = Self.workspaceID(rootID: rootID, childID: childID)
    await inputGate.acquire()
    defer { inputGate.release() }
    guard var record = try await workspaceRecord(id: id) else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.workspace_result")
    }
    let requested = try input.map(Self.requestedWorkspaceResolutions)
    if record.status == "pending" {
      guard
        requested == nil || requested == record.resolutions || requested == record.resolvedInputs
      else { throw ServiceStoreError.invalidArgument("embedded_dsh.workspace_busy") }
      return .object(try await workspaceFields(record))
    }
    if let requested, requested == record.resolvedInputs,
      requested.allSatisfy({ !record.conflicts.contains($0.relativePath) })
    {
      return .object(try await workspaceFields(record))
    }
    if retry || input != nil, record.status != "merged" {
      guard record.status != "recovery_required" else {
        throw ServiceStoreError.invalidArgument("embedded_dsh.workspace_recovery_required")
      }
      guard
        let child = try await application.embeddedDSHSubagent(
          parentSessionID: rootID, childID: childID), child.currentStatus?.isTerminal == true,
        child.currentTaskID?.rawValue == record.taskID
      else { throw ServiceStoreError.invalidArgument("embedded_dsh.workspace_busy") }
      if let resolutions = requested {
        guard ["conflict", "failed"].contains(record.status),
          resolutions.allSatisfy({ record.conflicts.contains($0.relativePath) }),
          let snapshot = try await workspaces.snapshot(id: id)
        else { throw ServiceStoreError.invalidArgument("embedded_dsh.workspace_resolutions") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var fingerprint = Data("\(id)\0\(record.taskID)\0\(snapshot.revision)\0".utf8)
        fingerprint.append(try encoder.encode(resolutions))
        record.resolutionRequestID = SHA256.hash(data: fingerprint)
          .map { String(format: "%02x", $0) }.joined()
        record.resolutions = resolutions
        record.resolvedInputs = nil
      }
      record.status = "pending"
      record.changedFiles = []
      record.changedFilesOmitted = 0
      try await persistWorkspaceRecordLocked(record)
      scheduleWorkspaceMerge(rootID: rootID, childID: childID)
    }
    return .object(try await workspaceFields(record))
  }

  private static func requestedWorkspaceResolutions(_ input: ACPJSONValue) throws
    -> [WorkbenchConflictResolution]
  {
    guard let values = input.arrayValue, !values.isEmpty, values.count <= 256 else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.workspace_resolutions")
    }
    var seen = Set<String>()
    return try values.map { value -> WorkbenchConflictResolution in
      guard let object = value.objectValue, let path = object["relativePath"]?.stringValue,
        seen.insert(path).inserted, let hash = object["expectedSHA256"],
        hash == .null || Self.validWorkspaceHash(hash)
      else { throw ServiceStoreError.invalidArgument("embedded_dsh.workspace_resolution") }
      return WorkbenchConflictResolution(relativePath: path, expectedSHA256: hash.stringValue)
    }.sorted { $0.relativePath < $1.relativePath }
  }

  private static func validWorkspaceHash(_ value: ACPJSONValue) -> Bool {
    guard let value = value.stringValue, value.utf8.count == 64 else { return false }
    return value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

}
