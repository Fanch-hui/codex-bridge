import BridgeACP
import BridgeFiles
import BridgeServiceCore
import Foundation

/// A condition no retry can repair by itself. The engine polls a child until its result is
/// terminal, so such a condition has to reach it as a failed result: an error would be retried
/// for ever.
struct PermanentWorkspaceFailure: Equatable {
  let reason: String
  /// The isolated copy itself cannot be read any more; the record is untouched.
  let copyUnavailable: Bool

  var fields: [String: ACPJSONValue] {
    var fields: [String: ACPJSONValue] = [
      "workspaceStatus": .string("failed"), "failureReason": .string(reason),
    ]
    if copyUnavailable { fields["workspaceUnavailable"] = .bool(true) }
    return fields
  }
}

extension ServiceEmbeddedDSHController {
  static let pendingMergeCapacityReason =
    "待合并的副本已达上限（256）。副本已保留；先处理其他待合并的副本，再用 bridge_agent_changes 重试合并。"
  static let reclaimedWorkspaceReason = "隔离副本已被清理（已合并的改动保留在项目中），无法继续此子 Agent。请重新委派一个新的子 Agent。"

  /// Permanent: the unmerged copy is gone from disk, or its repair chain is full. Everything
  /// else (a busy database, a cancelled call, a service shutting down, an unreadable record) may
  /// pass and stays an error, so the engine backs off and asks again.
  static func permanentWorkspaceFailure(_ error: any Error) -> PermanentWorkspaceFailure? {
    switch error {
    case AgentWorkspaceError.workspaceUnavailable:
      return PermanentWorkspaceFailure(
        reason: "隔离副本目录已不存在，其中未合并的变更无法读取。副本记录已保留，未被标记为可丢弃。",
        copyUnavailable: true)
    case ServiceStoreError.invalidArgument("embedded_dsh.workspace_lineage_capacity"):
      return PermanentWorkspaceFailure(
        reason: "同一子 Agent 的冲突修复轮次已达上限，无法继续记录合并状态。副本已保留，请先处理已有冲突。",
        copyUnavailable: false)
    default:
      return nil
    }
  }

  /// Results the engine has not acknowledged yet. A child that cannot be described this round is
  /// reported in `skipped` and comes back next round, so it never holds back the others.
  func subagentResults(rootID: String) async throws -> ACPJSONValue {
    var results: [ACPJSONValue] = []
    var skipped: [ACPJSONValue] = []
    for item in try await application.pendingEmbeddedDSHResults(parentSessionID: rootID) {
      let value: ACPJSONValue = .object([
        "childID": .string(item.childID), "requestID": .string(item.requestID),
        "taskID": .string(item.taskID.rawValue), "state": .string(item.status.rawValue),
        "output": item.resultSummary.map(ACPJSONValue.string) ?? .null,
        "error": item.failureCode.map(ACPJSONValue.string) ?? .null,
      ])
      do {
        results.append(
          try await enrichWorkspaceState(
            value, rootID: rootID, childID: item.childID,
            taskID: item.taskID.rawValue, state: item.status.rawValue))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        let mapped = BridgeServiceRequestController.map(error)
        skipped.append(
          .object([
            "childID": .string(item.childID), "requestID": .string(item.requestID),
            "error": .string("\(mapped.code): \(mapped.message)"),
          ]))
      }
    }
    var response: [String: ACPJSONValue] = ["results": .array(results)]
    if !skipped.isEmpty { response["skipped"] = .array(skipped) }
    return .object(response)
  }

  /// Removing a project deletes its tasks, so nothing is left to wait for or to acknowledge.
  /// Nil means the operation has no answer without the project.
  func resultAfterProjectRemoval(operation: String, payload: [String: ACPJSONValue]) async throws
    -> ACPJSONValue?
  {
    switch operation {
    case "results": return .object(["results": .array([])])
    case "ack": return .object([:])
    case "get", "wait":
      guard let taskID = payload["taskID"]?.stringValue,
        let childID = payload["childID"]?.stringValue
      else { return nil }
      let reason = "项目已被移除，子 Agent 的任务记录已一并删除。"
      var result: [String: ACPJSONValue] = [
        "childID": .string(childID), "taskID": .string(taskID), "state": .string("failed"),
        "terminal": .bool(true), "output": .null, "error": .string("project_removed"),
        "failureReason": .string(reason),
      ]
      if let requestID = payload["requestID"]?.stringValue {
        result["requestID"] = .string(requestID)
      }
      if let rootID = payload["rootSessionID"]?.stringValue {
        let mode = try await workspaceMode(rootID: rootID, childID: childID)
        result["workspaceMode"] = .string(mode)
        if mode == "isolated" { result["workspaceStatus"] = .string("failed") }
      }
      return .object(result)
    default: return nil
    }
  }
}
