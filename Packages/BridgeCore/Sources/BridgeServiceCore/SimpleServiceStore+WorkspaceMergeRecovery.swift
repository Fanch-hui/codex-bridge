import BridgeDomain
import Crypto
import Foundation

public struct ServiceWorkspaceMergeRecovery: Codable, Equatable, Sendable {
  public let projectID: ProjectID
  public let workspaceID: String
  public let rootID: String
  public let childID: String
  public let taskID: String
  public let instanceID: String?
  public var failureReason: String?

  public var recoveryID: String {
    instanceID.map { "merge:" + $0 } ?? workspaceID
  }

  public init(
    projectID: ProjectID, workspaceID: String, rootID: String, childID: String,
    taskID: String, failureReason: String? = nil,
    instanceID: String? = UUID().uuidString.lowercased()
  ) {
    self.projectID = projectID
    self.workspaceID = workspaceID
    self.rootID = rootID
    self.childID = childID
    self.taskID = taskID
    self.instanceID = instanceID
    self.failureReason = failureReason
  }
}

extension SimpleServiceStore {
  private static func workspaceMergeRecoveryKey(_ projectID: ProjectID) -> String {
    let digest = SHA256.hash(data: Data(projectID.rawValue.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return "embedded_dsh.workspace.recovery." + digest
  }

  public func workspaceMergeRecovery(projectID: ProjectID) throws
    -> ServiceWorkspaceMergeRecovery?
  {
    try workspaceMergeRecoveries(projectID: projectID).first
  }

  public func workspaceMergeRecoveries(projectID: ProjectID) throws
    -> [ServiceWorkspaceMergeRecovery]
  {
    let key = Self.workspaceMergeRecoveryKey(projectID)
    guard let value = try setting(key: key)?.value, !value.isEmpty else { return [] }
    let records = try JSONDecoder().decode(
      [ServiceWorkspaceMergeRecovery].self, from: Data(value.utf8))
    guard records.allSatisfy({ $0.projectID == projectID }),
      Set(records.map(\.workspaceID)).count == records.count
    else { throw ServiceStoreError.corruptRecord }
    return records
  }

  public func setWorkspaceMergeRecovery(_ record: ServiceWorkspaceMergeRecovery) throws {
    let key = Self.workspaceMergeRecoveryKey(record.projectID)
    try updateSettingsAtomically(keys: [key], updatedAt: Date()) { current in
      var records: [ServiceWorkspaceMergeRecovery] = []
      if let previous = current[key], !previous.isEmpty {
        records = try JSONDecoder().decode(
          [ServiceWorkspaceMergeRecovery].self, from: Data(previous.utf8))
        guard records.allSatisfy({ $0.projectID == record.projectID }) else {
          throw ServiceStoreError.corruptRecord
        }
        if let existing = records.first(where: { $0.workspaceID == record.workspaceID }),
          existing.recoveryID != record.recoveryID
        {
          throw ServiceStoreError.invalidArgument("workspace.recovery_owner")
        }
      }
      records.removeAll { $0.workspaceID == record.workspaceID }
      records.append(record)
      guard records.count <= 64,
        let value = String(data: try JSONEncoder().encode(records), encoding: .utf8)
      else { throw ServiceStoreError.invalidArgument("workspace.recovery_capacity") }
      _ = try ServiceSettingRecord(key: key, value: value, updatedAt: Date())
      return [key: value]
    }
  }

  public func clearWorkspaceMergeRecovery(
    projectID: ProjectID, workspaceID: String, recoveryID: String? = nil
  ) throws {
    let key = Self.workspaceMergeRecoveryKey(projectID)
    try updateSettingsAtomically(keys: [key], updatedAt: Date()) { current in
      guard let previous = current[key], !previous.isEmpty else { return [:] }
      var records = try JSONDecoder().decode(
        [ServiceWorkspaceMergeRecovery].self, from: Data(previous.utf8))
      guard records.allSatisfy({ $0.projectID == projectID }) else {
        throw ServiceStoreError.corruptRecord
      }
      if let recoveryID, let existing = records.first(where: { $0.workspaceID == workspaceID }),
        existing.recoveryID != recoveryID
      {
        throw ServiceStoreError.invalidArgument("workspace.recovery_owner")
      }
      records.removeAll { $0.workspaceID == workspaceID }
      guard !records.isEmpty else { return [key: ""] }
      guard let value = String(data: try JSONEncoder().encode(records), encoding: .utf8) else {
        throw ServiceStoreError.corruptRecord
      }
      return [key: value]
    }
  }
}

extension ServiceTaskManager {
  public func workspaceMergeRecovery(projectID: ProjectID) async throws
    -> ServiceWorkspaceMergeRecovery?
  {
    try await store.workspaceMergeRecovery(projectID: projectID)
  }

  public func workspaceMergeRecoveries(projectID: ProjectID) async throws
    -> [ServiceWorkspaceMergeRecovery]
  {
    try await store.workspaceMergeRecoveries(projectID: projectID)
  }
}
