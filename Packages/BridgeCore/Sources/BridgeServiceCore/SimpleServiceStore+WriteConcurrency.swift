import BridgeDomain
import Foundation
import GRDB

/// Standalone full-permission tasks share one execution group per project. A limit of 1 keeps
/// the group exclusive; a higher limit (4 by default) lets further standalone tasks join the
/// same group in the shared project directory. Workbench root groups never
/// accept standalone joiners.
enum StandaloneWriteSlot: Equatable {
  case free
  case join(groupID: String)
  case full
}

extension SimpleServiceStore {
  public func hasProjectWriteCapacity(projectID: ProjectID) throws -> Bool {
    do {
      return try database.read { db in
        try Self.standaloneWriteSlot(projectID: projectID, in: db) != .full
      }
    } catch {
      throw ServiceStoreError.storageFailure
    }
  }

  static func standaloneWriteSlot(projectID: ProjectID, in db: Database) throws
    -> StandaloneWriteSlot
  {
    guard let group = try executionGroup(projectID: projectID, in: db) else { return .free }
    guard group["root_session_id"] as String? == nil else { return .full }
    let limit = try projectWriteConcurrency(in: db)
    guard limit > 1 else { return .full }
    let groupID: String = group["group_id"]
    let active =
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM bridge_service_tasks
          WHERE execution_group_id = ? AND permission_mode = 'workspace-write'
            AND queue_state = 'active'
            AND status IN ('awaiting_local_approval', 'starting', 'running',
                           'waiting_for_codex_approval', 'unknown')
          """,
        arguments: [groupID]
      ) ?? 0
    return active < limit ? .join(groupID: groupID) : .full
  }

  static func projectWriteConcurrency(in db: Database) throws -> Int {
    guard
      let value = try String.fetchOne(
        db,
        sql: "SELECT setting_value FROM bridge_service_settings WHERE setting_key = ?",
        arguments: [ServiceSettingKey.projectWriteConcurrency.rawValue]
      )
    else { return ServiceSettings.defaultProjectWriteConcurrency }
    guard let limit = Int(value), ServiceSettings.projectWriteConcurrencyRange.contains(limit)
    else { return ServiceSettings.defaultProjectWriteConcurrency }
    return limit
  }
}
