import BridgeACP
import BridgeAgentCore
import BridgeCodexRPC
import BridgeDomain
import BridgeEmbeddedDSH
import BridgeFiles
import BridgeMCP
import BridgeSecurity
import BridgeServiceCore
import Crypto
import Foundation

struct WorkbenchConflictResolution: Codable, Equatable, Sendable {
  let relativePath: String
  let expectedSHA256: String?
}

struct WorkbenchWorkspaceRecord: Codable, Sendable {
  let rootID: String
  let childID: String
  let taskID: String
  var status: String
  var changedFiles: [String]
  var conflicts: [String]
  var changedFilesOmitted: Int? = nil
  var conflictsOmitted: Int? = nil
  var resolutions: [WorkbenchConflictResolution]? = nil
  var resolvedInputs: [WorkbenchConflictResolution]? = nil
  var resolutionRequestID: String? = nil
  var resolutionArchiveID: String? = nil
  var failureReason: String? = nil
  var candidateID: String? = nil
  var candidatePath: String? = nil
  var supersededTaskIDs: [String]? = nil

  mutating func setPaths(changedFiles: [String], conflicts: [String]) {
    let changed = Self.sample(changedFiles, allowOversizedFirst: false)
    let conflicted = Self.sample(conflicts, allowOversizedFirst: true)
    self.changedFiles = changed.paths
    self.changedFilesOmitted = changed.omitted
    self.conflicts = conflicted.paths
    self.conflictsOmitted = conflicted.omitted
  }

  private static func sample(_ paths: [String], allowOversizedFirst: Bool)
    -> (paths: [String], omitted: Int)
  {
    var result: [String] = []
    var bytes = 0
    for path in paths {
      // Bound the JSON representation, including escaping and array punctuation.
      let cost = path.utf8.reduce(3) { size, byte in
        if byte < 0x20 { return size + 6 }
        if byte == 0x22 || byte == 0x2f || byte == 0x5c || byte >= 0x80 { return size + 2 }
        return size + 1
      }
      guard bytes + cost <= 4 * 1_024 || (result.isEmpty && allowOversizedFirst) else { break }
      result.append(path)
      bytes += cost
    }
    return (result, paths.count - result.count)
  }
}

extension ServiceEmbeddedDSHController {
  private static let pendingWorkspacesKey = "embedded_dsh.workspace.pending"

  static func workspaceID(rootID: String, childID: String) -> String {
    EmbeddedDSHSubagentIdentity(parentSessionID: rootID, childID: childID).sourceClientID
  }

  static func workspaceModeKey(_ id: String) -> String {
    "embedded_dsh.workspace.active." + id
  }

  static func workspaceReasonKey(_ id: String) -> String {
    "embedded_dsh.workspace.reason." + id
  }

  private static func workspaceStatusKey(_ id: String) -> String {
    "embedded_dsh.workspace.status." + id
  }

  private static func workspaceTaskStatusKey(_ id: String, taskID: String) -> String {
    let digest = SHA256.hash(data: Data((id + "\0" + taskID).utf8))
      .map { String(format: "%02x", $0) }.joined()
    return "embedded_dsh.workspace.task." + digest
  }

  func workspaceMode(rootID: String, childID: String) async throws -> String {
    let id = Self.workspaceID(rootID: rootID, childID: childID)
    return try await store.setting(key: Self.workspaceModeKey(id))?.value ?? "shared"
  }

  func workspaceReason(rootID: String, childID: String) async throws -> String? {
    let id = Self.workspaceID(rootID: rootID, childID: childID)
    guard let value = try await store.setting(key: Self.workspaceReasonKey(id))?.value,
      !value.isEmpty
    else { return nil }
    return value
  }

  func workspaceRecord(id: String, taskID: String? = nil) async throws -> WorkbenchWorkspaceRecord?
  {
    if let taskID,
      let historical = try await store.setting(
        key: Self.workspaceTaskStatusKey(id, taskID: taskID))
    {
      return try JSONDecoder().decode(
        WorkbenchWorkspaceRecord.self, from: Data(historical.value.utf8))
    }
    guard let current = try await store.setting(key: Self.workspaceStatusKey(id)) else {
      return nil
    }
    let record = try JSONDecoder().decode(
      WorkbenchWorkspaceRecord.self, from: Data(current.value.utf8))
    return taskID == nil || taskID == record.taskID ? record : nil
  }

  func pendingWorkspaces(includeValidationRequired: Bool = false) async throws
    -> [WorkbenchWorkspaceRecord]
  {
    guard let setting = try await store.setting(key: Self.pendingWorkspacesKey) else { return [] }
    var records: [WorkbenchWorkspaceRecord] = []
    for key in try Self.pendingWorkspaceKeys(setting.value) {
      let record: WorkbenchWorkspaceRecord?
      if key.hasPrefix("embedded.dsh.") {
        record = try await workspaceRecord(id: key)
      } else if let stored = try await store.setting(key: key) {
        record = try JSONDecoder().decode(
          WorkbenchWorkspaceRecord.self, from: Data(stored.value.utf8))
      } else {
        record = nil
      }
      guard let record else {
        throw AgentWorkspaceError.invalidStorage
      }
      if record.status == "pending"
        || (includeValidationRequired && record.status == "validation_required")
      {
        records.append(record)
      }
    }
    return records
  }

  private static func pendingWorkspaceKeys(_ value: String) throws -> [String] {
    let data = Data(value.utf8)
    if let ids = try? JSONDecoder().decode([String].self, from: data) { return ids }
    let records = try JSONDecoder().decode([WorkbenchWorkspaceRecord].self, from: data)
    return records.map {
      let id = workspaceID(rootID: $0.rootID, childID: $0.childID)
      return workspaceTaskStatusKey(id, taskID: $0.taskID)
    }
  }

  func persistWorkspaceRecord(_ record: WorkbenchWorkspaceRecord) async throws {
    await inputGate.acquire()
    defer { inputGate.release() }
    try await persistWorkspaceRecordLocked(record)
  }

  private func ensureWorkspaceRecord(
    rootID: String, childID: String, taskID: String, state: String
  ) async throws -> WorkbenchWorkspaceRecord {
    await inputGate.acquire()
    defer { inputGate.release() }
    let id = Self.workspaceID(rootID: rootID, childID: childID)
    if let record = try await workspaceRecord(id: id, taskID: taskID) { return record }
    let child = try await application.embeddedDSHSubagent(
      parentSessionID: rootID, childID: childID)
    guard child?.currentTaskID?.rawValue == taskID else {
      throw ServiceStoreError.invalidArgument("embedded_dsh.workspace_history")
    }
    let previous = try await workspaceRecord(id: id)
    var lineage: [String] = []
    if let previous, previous.taskID != taskID, previous.status != "merged",
      previous.status == "conflict" || !(previous.supersededTaskIDs?.isEmpty ?? true)
    {
      lineage = previous.supersededTaskIDs ?? []
      if !lineage.contains(previous.taskID) { lineage.append(previous.taskID) }
      guard lineage.count <= 128 else {
        throw ServiceStoreError.invalidArgument("embedded_dsh.workspace_lineage_capacity")
      }
    }
    var initial = WorkbenchWorkspaceRecord(
      rootID: rootID, childID: childID, taskID: taskID,
      status: state == "completed" ? "pending" : "retained", changedFiles: [], conflicts: [])
    initial.supersededTaskIDs = lineage.isEmpty ? nil : lineage
    try await persistWorkspaceRecordLocked(initial)
    return initial
  }

  func persistWorkspaceRecordLocked(_ record: WorkbenchWorkspaceRecord) async throws {
    let id = Self.workspaceID(rootID: record.rootID, childID: record.childID)
    let statusKey = Self.workspaceStatusKey(id)
    let taskKey = Self.workspaceTaskStatusKey(id, taskID: record.taskID)
    let indexKey = Self.pendingWorkspacesKey
    let lineageKeys =
      record.status == "merged"
      ? (record.supersededTaskIDs ?? []).map { Self.workspaceTaskStatusKey(id, taskID: $0) } : []
    guard lineageKeys.count <= 128, Set(lineageKeys).count == lineageKeys.count,
      !lineageKeys.contains(taskKey)
    else { throw ServiceStoreError.invalidArgument("embedded_dsh.workspace_lineage") }
    let now = Date()
    try await store.updateSettingsAtomically(
      keys: [statusKey, taskKey, indexKey] + lineageKeys, updatedAt: now
    ) {
      values in
      var pending: [String] = []
      if let stored = values[indexKey] {
        pending = try Self.pendingWorkspaceKeys(stored)
      }
      let previousTaskKey: String?
      if let stored = values[statusKey] {
        let previous = try JSONDecoder().decode(
          WorkbenchWorkspaceRecord.self, from: Data(stored.utf8))
        previousTaskKey = Self.workspaceTaskStatusKey(id, taskID: previous.taskID)
      } else {
        previousTaskKey = nil
      }
      pending.removeAll { $0 == id || $0 == taskKey || $0 == previousTaskKey }
      if ["pending", "validation_required"].contains(record.status) {
        guard pending.count < 256 else {
          throw ServiceStoreError.invalidArgument("embedded_dsh.workspace_pending_capacity")
        }
        pending.append(taskKey)
      }
      let encoder = JSONEncoder()
      guard let value = String(data: try encoder.encode(record), encoding: .utf8),
        let index = String(data: try encoder.encode(pending), encoding: .utf8)
      else { throw AgentWorkspaceError.invalidStorage }
      _ = try ServiceSettingRecord(key: statusKey, value: value, updatedAt: now)
      _ = try ServiceSettingRecord(key: taskKey, value: value, updatedAt: now)
      _ = try ServiceSettingRecord(key: indexKey, value: index, updatedAt: now)
      var updated = [statusKey: value, taskKey: value, indexKey: index]
      for (key, expectedTaskID) in zip(lineageKeys, record.supersededTaskIDs ?? []) {
        guard let stored = values[key] else { throw AgentWorkspaceError.invalidStorage }
        var previous = try JSONDecoder().decode(
          WorkbenchWorkspaceRecord.self, from: Data(stored.utf8))
        guard previous.rootID == record.rootID, previous.childID == record.childID,
          previous.taskID == expectedTaskID
        else {
          throw AgentWorkspaceError.invalidStorage
        }
        previous.status = "merged"
        previous.conflicts = []
        previous.conflictsOmitted = 0
        previous.failureReason = nil
        guard let historical = String(data: try encoder.encode(previous), encoding: .utf8) else {
          throw AgentWorkspaceError.invalidStorage
        }
        updated[key] = historical
      }
      return updated
    }
  }

  func workspaceFields(_ record: WorkbenchWorkspaceRecord) async throws
    -> [String: ACPJSONValue]
  {
    let id = Self.workspaceID(rootID: record.rootID, childID: record.childID)
    guard let snapshot = try await workspaces.snapshot(id: id) else {
      throw AgentWorkspaceError.workspaceUnavailable
    }
    var result: [String: ACPJSONValue] = [
      "workspaceMode": .string("isolated"), "workspaceStatus": .string(record.status),
      "changedFiles": .array(record.changedFiles.map(ACPJSONValue.string)),
      "conflicts": .array(record.conflicts.map(ACPJSONValue.string)),
      "changedFilesOmitted": .integer(Int64(record.changedFilesOmitted ?? 0)),
      "conflictsOmitted": .integer(Int64(record.conflictsOmitted ?? 0)),
    ]
    if record.status != "merged" {
      result["workspacePath"] = .string(snapshot.workspaceRoot.canonicalPath)
    }
    if record.status == "conflict" {
      result["canRepairWithAgent"] = .bool(try await workspaces.canRepairConflicts(id: id))
    }
    if let archiveID = record.resolutionArchiveID {
      result["resolutionArchiveID"] = .string(archiveID)
    }
    if let reason = record.failureReason {
      result["failureReason"] = .string(reason)
    }
    if let candidatePath = record.candidatePath {
      result["candidatePath"] = .string(candidatePath)
    }
    return result
  }

  func enrichWorkspaceState(
    _ value: ACPJSONValue, rootID: String, childID: String,
    taskID: String, state: String
  ) async throws -> ACPJSONValue {
    let mode = try await workspaceMode(rootID: rootID, childID: childID)
    var result = value.objectValue ?? [:]
    result["workspaceMode"] = .string(mode)
    if let reason = try await workspaceReason(rootID: rootID, childID: childID) {
      result["workspaceReason"] = .string(reason)
    }
    guard mode == "isolated", ["completed", "failed", "interrupted"].contains(state) else {
      return .object(result)
    }
    let record = try await ensureWorkspaceRecord(
      rootID: rootID, childID: childID, taskID: taskID, state: state)
    if record.status == "pending" {
      scheduleWorkspaceMerge(rootID: rootID, childID: childID)
    }
    result.merge(try await workspaceFields(record)) { _, new in new }
    return .object(result)
  }

}
