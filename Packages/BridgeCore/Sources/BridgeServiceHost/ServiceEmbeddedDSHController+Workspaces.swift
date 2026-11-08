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
  func prepareSubagentWorkspace(
    rootID: String, childID: String, projectID: ProjectID, providerID: String,
    installationID: String?,
    permissionMode: ServicePermissionMode, continuation: Bool
  ) async throws -> (mode: String, synchronizedPaths: [String], repairPaths: [String]) {
    if permissionMode == .full,
      try await application.pendingWorkspaceMergeRecovery(projectID: projectID) != nil
    {
      throw ServiceStoreError.invalidArgument("embedded_dsh.workspace_recovery_required")
    }
    let id = Self.workspaceID(rootID: rootID, childID: childID)
    let setting = try await store.setting(key: Self.workspaceModeKey(id))
    if let setting {
      if setting.value == "isolated" {
        if continuation, providerID == "codex", !CodexIsolatedLaunch.supportsFileOnlyExecution {
          try await store.setSetting(
            ServiceSettingRecord(
              key: Self.workspaceReasonKey(id),
              value: "此 Codex 副本保留原变更；处理完变更后，请新建共享目录任务。", updatedAt: Date()))
          throw AgentWorkspaceError.workspaceUnavailable
        }
        guard
          providerID == "codex"
            ? CodexIsolatedLaunch.isAvailable : WorkspaceProcessIsolation.isAvailable,
          let snapshot = try await workspaces.snapshot(id: id)
        else { throw AgentWorkspaceError.workspaceUnavailable }
        let root = try await registeredProjectRoot(projectID)
        guard snapshot.projectRoot == root else { throw AgentWorkspaceError.projectMismatch }
        if continuation {
          let child = try await application.embeddedDSHSubagent(
            parentSessionID: rootID, childID: childID)
          guard let record = try await workspaceRecord(id: id),
            record.taskID == child?.currentTaskID?.rawValue,
            child?.currentStatus?.isTerminal == true,
            !["pending", "failed", "validation_required", "recovery_required"]
              .contains(record.status)
          else { throw ServiceStoreError.invalidArgument("embedded_dsh.workspace_pending") }
          if record.status != "merged",
            record.status == "conflict"
              || !(record.supersededTaskIDs?.isEmpty ?? true)
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
            return (setting.value, [], Self.workspaceSynchronizationSummary(paths))
          }
          if record.status == "merged" {
            let paths = try await workspaces.synchronize(id: id)
            return (setting.value, Self.workspaceSynchronizationSummary(paths), [])
          }
        }
      }
      guard ["isolated", "shared"].contains(setting.value) else {
        throw ServiceStoreError.invalidArgument("embedded_dsh.workspace_mode")
      }
      return (setting.value, [], [])
    }
    // A pre-existing native session is bound to the original project directory.
    var mode = "shared"
    var reason: String?
    if continuation {
      reason = "此会话沿用原来的项目目录。"
    } else if providerID == "codex", !CodexIsolatedLaunch.supportsFileOnlyExecution {
      reason = "当前 Codex 文件操作依赖命令进程，使用共享目录串行执行。"
    } else if permissionMode == .full,
      !(providerID == "codex"
        ? CodexIsolatedLaunch.isAvailable : WorkspaceProcessIsolation.isAvailable)
    {
      reason = "当前平台的隔离检查未通过。"
    }
    if !continuation, permissionMode == .full,
      providerID != "codex" || CodexIsolatedLaunch.supportsFileOnlyExecution,
      providerID == "codex"
        ? CodexIsolatedLaunch.isAvailable : WorkspaceProcessIsolation.isAvailable
    {
      let root = try await registeredProjectRoot(projectID)
      do {
        let snapshot = try await workspaces.prepare(id: id, projectRoot: root)
        let readiness: (ready: Bool, reason: String?)
        if providerID == "codex" {
          readiness = try await isolatedWorkspaceIsReady(snapshot)
        } else if let installationID {
          let result = try await externalWorkspaceIsReady(
            providerID: providerID, installationID: installationID, snapshot: snapshot)
          readiness = (result.ready, result.reason)
        } else {
          readiness = (false, "此 Agent 尚未提供可验证的进程隔离。")
        }
        if readiness.ready {
          try await workspaces.markStarted(id: id)
          mode = "isolated"
          reason = readiness.reason
        } else {
          _ = try await workspaces.discardPrepared(id: id)
          reason = readiness.reason
        }
      } catch let error as AgentWorkspaceError {
        switch error {
        case .unsupportedEntry:
          mode = "shared"
          reason = "项目包含暂不支持隔离的文件。"
        case .resourceLimit:
          mode = "shared"
          reason = "项目超出独立副本的资源限额。"
        case .gitUnavailable:
          mode = "shared"
          reason = "项目的独立 Git 副本暂不可用。"
        default: throw error
        }
      }
    }
    let modeKey = Self.workspaceModeKey(id)
    let reasonKey = Self.workspaceReasonKey(id)
    let savedMode = mode
    let savedReason = reason ?? ""
    try await store.updateSettingsAtomically(keys: [modeKey, reasonKey], updatedAt: Date()) { _ in
      [modeKey: savedMode, reasonKey: savedReason]
    }
    return (mode, [], [])
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

  private func registeredProjectRoot(_ projectID: ProjectID) async throws -> RegisteredRoot {
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
