import BridgeFiles
import BridgeSecurity
import Foundation

extension ServiceEmbeddedDSHController {
  private static let maximumReclaimRounds = 3

  /// Prepares an isolated copy. At the managed limit it first deletes merged copies nobody can
  /// still run in (least recently used first); copies holding unmerged work are never touched.
  ///
  /// The copy runs without `inputGate`. Only the step that judges a copy idle and deletes it takes
  /// the gate, because a continuation enters an existing copy under the same gate; a copy being
  /// continued is therefore never reclaimed. A copy that is still being prepared has no merged
  /// result record, so it is never idle either.
  func prepareWorkspaceReclaimingIfFull(id: String, projectRoot: RegisteredRoot) async throws
    -> AgentWorkspaceSnapshot
  {
    var reclaimRounds = 0
    while true {
      do {
        return try await workspaces.prepare(id: id, projectRoot: projectRoot)
      } catch AgentWorkspaceError.workspaceCapacityReached
        where reclaimRounds < Self.maximumReclaimRounds
      {
        reclaimRounds += 1
        guard try await reclaimMergedWorkspaceUnderInputGate() else {
          throw AgentWorkspaceError.workspaceCapacityReached
        }
      }
    }
  }

  /// Short and gated: one candidate is verified on disk (a hash comparison of its two trees) and
  /// removed. It only runs when the store is full.
  private func reclaimMergedWorkspaceUnderInputGate() async throws -> Bool {
    await inputGate.acquire()
    defer { inputGate.release() }
    try Task.checkCancellation()
    let reclaimed = try await workspaces.reclaimMergedWorkspaces {
      await self.isMergedWorkspaceIdle($0)
    }
    return !reclaimed.isEmpty
  }

  /// A copy may go once its latest result is merged and its child has no active task. The store
  /// still verifies on disk that nothing unmerged remains.
  func isMergedWorkspaceIdle(_ id: String) async -> Bool {
    do {
      guard let record = try await workspaceRecord(id: id), record.status == "merged" else {
        return false
      }
      guard
        let child = try await application.embeddedDSHSubagent(
          parentSessionID: record.rootID, childID: record.childID)
      else { return true }
      return child.currentTaskID?.rawValue == record.taskID
        && child.currentStatus?.isTerminal == true
    } catch {
      // An unreadable record is never grounds for deleting a copy.
      return false
    }
  }

  /// Archived conflict versions are only a safety net until the resolved result is merged.
  func discardResolvedConflictArchives(workspaceID: String) async {
    do { try await workspaces.discardResolvedConflictArchives(id: workspaceID) } catch {
      // Cleanup only: the merge is already recorded and the archives go away with the copy.
    }
  }

  /// Why a new subagent runs in the shared directory instead of an isolated copy. Returns nil for
  /// errors that must surface. Only the path and its category are named, never file content.
  static func isolationFallbackReason(for error: AgentWorkspaceError) -> String? {
    switch error {
    case .symbolicLink(let path): return "项目含符号链接，暂不支持隔离：" + displayPath(path)
    case .suspectedSecret(let path): return "项目文件疑似含密钥，暂不支持隔离：" + displayPath(path)
    case .unsupportedEntry(let path): return "项目含暂不支持隔离的文件类型：" + displayPath(path)
    case .workspaceCapacityReached:
      return "隔离副本数量已达上限，且现有副本都含未合并内容或仍在使用，本次改用共享目录。"
    case .resourceLimit: return "项目超出独立副本的资源限额。"
    case .gitUnavailable: return "项目的独立 Git 副本暂不可用。"
    default: return nil
    }
  }

  private static func displayPath(_ path: String) -> String {
    let cleaned = String(
      String.UnicodeScalarView(
        path.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
    return cleaned.count > 160 ? String(cleaned.prefix(160)) + "…" : cleaned
  }
}
