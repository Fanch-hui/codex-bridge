import BridgeDomain
import Foundation
import GRDB

/// Maps a `bridge_service_subagent_rounds` row to and from `SubagentRound`.
enum SubagentRoundCodec {
  static let table = "bridge_service_subagent_rounds"

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  static let insertColumns = """
    root_id, child_id, request_id, project_id, ordinal, parent_session_id, installation_id, kind,
    phase, fingerprint, prompt, options_json, access, repair_conflict, dependencies_json,
    previous_request_id, previous_task_id, previous_run_id, requested_after_terminal, task_id,
    waiting_reason, failure_reason, failure_origin, dispatch_error, delivery_required, delivered,
    workspace_mode, write_scope, reservation_held, lease_held, child_created_at, created_at,
    updated_at, settled_at
    """

  static var insertPlaceholders: String {
    Array(repeating: "?", count: 34).joined(separator: ", ")
  }

  static func arguments(_ round: SubagentRound) throws -> StatementArguments {
    let options = String(decoding: try encoder.encode(round.options), as: UTF8.self)
    let dependencies = String(decoding: try encoder.encode(round.dependencies), as: UTF8.self)
    let values: [DatabaseValueConvertible?] = [
      round.key.rootID, round.key.childID, round.key.requestID, round.projectID.rawValue,
      round.ordinal, round.parentSessionID, round.installationID, round.kind.rawValue,
      round.phase.rawValue, round.fingerprint, round.prompt, options, round.access?.rawValue,
      round.repairConflict, dependencies, round.previousRequestID, round.previousTaskID,
      round.previousRunID, round.requestedAfterTerminal, round.taskID, round.waitingReason,
      round.failureReason, round.failureOrigin?.rawValue, round.dispatchError,
      round.deliveryRequired, round.delivered, round.workspaceMode?.rawValue,
      round.writeScope?.rawValue, round.reservationHeld, round.leaseHeld,
      round.childCreatedAt.timeIntervalSince1970, round.createdAt.timeIntervalSince1970,
      round.updatedAt.timeIntervalSince1970, round.settledAt?.timeIntervalSince1970,
    ]
    return StatementArguments(values)
  }

  static func decode(_ row: Row) throws -> SubagentRound {
    let decoder = JSONDecoder()
    guard let kind = SubagentRoundKind(rawValue: row["kind"]),
      let phase = SubagentRoundPhase(rawValue: row["phase"]),
      let options = try? decoder.decode(
        SubagentRoundOptions.self, from: Data((row["options_json"] as String).utf8)),
      let dependencies = try? decoder.decode(
        [SubagentRoundDependency].self, from: Data((row["dependencies_json"] as String).utf8))
    else { throw ServiceStoreError.corruptRecord }
    let draft = SubagentRoundDraft(
      key: SubagentRoundKey(
        rootID: row["root_id"], childID: row["child_id"], requestID: row["request_id"]),
      projectID: ProjectID(rawValue: row["project_id"]),
      parentSessionID: row["parent_session_id"], installationID: row["installation_id"],
      kind: kind, phase: phase, fingerprint: row["fingerprint"], prompt: row["prompt"],
      options: options, access: try optional(row["access"]),
      repairConflict: (row["repair_conflict"] as Int) != 0, dependencies: dependencies,
      previousRequestID: row["previous_request_id"], previousTaskID: row["previous_task_id"],
      previousRunID: row["previous_run_id"],
      requestedAfterTerminal: (row["requested_after_terminal"] as Int) != 0,
      taskID: row["task_id"], waitingReason: row["waiting_reason"],
      failureReason: row["failure_reason"], failureOrigin: try optional(row["failure_origin"]),
      dispatchError: row["dispatch_error"],
      deliveryRequired: (row["delivery_required"] as Int) != 0,
      delivered: (row["delivered"] as Int) != 0, workspaceMode: try optional(row["workspace_mode"]),
      writeScope: try optional(row["write_scope"]),
      reservationHeld: (row["reservation_held"] as Int) != 0,
      leaseHeld: (row["lease_held"] as Int) != 0,
      childCreatedAt: Date(timeIntervalSince1970: row["child_created_at"]),
      createdAt: Date(timeIntervalSince1970: row["created_at"]))
    let settled: Double? = row["settled_at"]
    return SubagentRound(
      draft: draft, ordinal: row["ordinal"],
      updatedAt: Date(timeIntervalSince1970: row["updated_at"]),
      settledAt: settled.map { Date(timeIntervalSince1970: $0) })
  }

  private static func optional<T: RawRepresentable>(_ raw: String?) throws -> T?
  where T.RawValue == String {
    guard let raw else { return nil }
    guard let value = T(rawValue: raw) else { throw ServiceStoreError.corruptRecord }
    return value
  }
}
