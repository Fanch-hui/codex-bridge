import BridgeSecurity
import Foundation

extension AgentWorkspaceStore {
  /// A journal exists before the first project file is replaced and remains until recovery ends.
  public func mergeRecovery(id: String) throws -> AgentWorkspaceMergeRecovery? {
    try validateIdentifier(id)
    guard FileManager.default.fileExists(atPath: journalURL(id).path) else { return nil }
    let manifest = try readManifest(id: id)
    guard manifest.version == 1, manifest.id == id else { throw AgentWorkspaceError.invalidStorage }
    let journal = try readJSON(AgentWorkspaceJournal.self, id: id, name: "merge-journal.json")
    guard journal.id == id,
      journal.phase == nil || journal.phase == "apply" || journal.phase == "rollback"
    else { throw AgentWorkspaceError.invalidStorage }
    let project = ProjectPathResolver(root: manifest.projectRoot)
    var applied: [String] = []
    var pending: [String] = []
    var diverged: [String] = []
    var inspectionError: String?
    do {
      try manifest.projectRoot.validateCurrentIdentity()
      for change in journal.changes {
        let current = try writer.readContent(
          relativePath: SecureRelativePath(change.path), through: project)
        if current == change.before {
          pending.append(change.path)
        } else if current == change.after {
          applied.append(change.path)
        } else {
          diverged.append(change.path)
        }
      }
      try manifest.projectRoot.validateCurrentIdentity()
    } catch {
      applied.removeAll()
      pending.removeAll()
      diverged.removeAll()
      inspectionError = Self.recoveryReason(error)
    }
    return AgentWorkspaceMergeRecovery(
      id: id, projectRoot: manifest.projectRoot, changedPaths: journal.changes.map(\.path),
      appliedPaths: applied, pendingPaths: pending, divergedPaths: diverged,
      isRollingBack: journal.phase == "rollback", failureReason: journal.failureReason,
      inspectionError: inspectionError)
  }

  public func pendingMergeRecoveries() throws -> [AgentWorkspaceMergeRecovery] {
    _ = try ensureManagementRoot()
    var result: [AgentWorkspaceMergeRecovery] = []
    for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() {
      guard FileManager.default.fileExists(atPath: journalURL(name).path) else { continue }
      if let recovery = try mergeRecovery(id: name) { result.append(recovery) }
    }
    return result
  }

  /// Roll back only journal-owned versions; a changed file remains untouched for review.
  @discardableResult
  public func rollbackMerge(id: String) throws -> Bool {
    try validateIdentifier(id)
    guard activeIDs.insert(id).inserted else { throw AgentWorkspaceError.workspaceBusy }
    defer { activeIDs.remove(id) }
    guard FileManager.default.fileExists(atPath: journalURL(id).path) else { return false }
    guard let snapshot = try snapshot(id: id) else {
      throw AgentWorkspaceError.workspaceUnavailable
    }
    var journal = try readJSON(AgentWorkspaceJournal.self, id: id, name: "merge-journal.json")
    let manifest = try readManifest(id: id)
    guard journal.id == id,
      journal.phase == nil || journal.phase == "apply" || journal.phase == "rollback",
      manifest.revision == journal.revision
    else { throw AgentWorkspaceError.recoveryRequired(journal.changes.map(\.path)) }
    let project = ProjectPathResolver(root: snapshot.projectRoot)
    let workspace = ProjectPathResolver(root: snapshot.workspaceRoot)
    let baseline = ProjectPathResolver(root: try baselineRoot(manifest))
    for change in journal.changes {
      let path = try SecureRelativePath(change.path)
      let current = try writer.readContent(relativePath: path, through: project)
      let child = try writer.readContent(relativePath: path, through: workspace)
      let original = try writer.readContent(relativePath: path, through: baseline)
      guard current == change.before || current == change.after, child == change.workspace,
        original == change.baseline || original == change.workspace
      else { throw AgentWorkspaceError.revisionConflict(change.path) }
      if change.before != nil, change.after == nil, change.beforeMode == nil {
        throw AgentWorkspaceError.recoveryRequired([change.path])
      }
      if let beforeMode = change.beforeMode, current != nil,
        !(journal.phase == "rollback" && change.after == nil && current == change.before)
      {
        guard
          try AgentWorkspaceInventory.mode(at: snapshot.projectRoot, path: change.path)
            == beforeMode
        else { throw AgentWorkspaceError.revisionConflict(change.path) }
      }
    }
    if journal.phase != "rollback" {
      journal.phase = "rollback"
      try writeJSON(journal, to: journalURL(id))
    }
    do {
      for change in journal.changes {
        try applyValue(
          change.before, previous: change.after, path: SecureRelativePath(change.path),
          resolver: project)
        if let beforeMode = change.beforeMode, change.after == nil, change.before != nil {
          try AgentWorkspaceInventory.setMode(
            beforeMode, at: snapshot.projectRoot, path: change.path)
        }
      }
      for change in journal.changes {
        try applyValue(
          change.baseline, previous: change.workspace, path: SecureRelativePath(change.path),
          resolver: baseline)
      }
      try FileManager.default.removeItem(at: journalURL(id))
      return true
    } catch {
      throw recordMergeFailure(error, journal: journal)
    }
  }

  func recordMergeFailure(_ error: any Error, journal: AgentWorkspaceJournal)
    -> AgentWorkspaceRecoveryFailure
  {
    let reason = Self.recoveryReason(error)
    var failed = journal
    failed.failureReason = reason
    var journalFailure: String?
    do { try writeJSON(failed, to: journalURL(journal.id)) } catch {
      journalFailure = Self.recoveryReason(error)
    }
    return AgentWorkspaceRecoveryFailure(
      paths: journal.changes.map(\.path), failureReason: reason,
      journalFailureReason: journalFailure)
  }

  static func recoveryReason(_ error: any Error) -> String {
    let value = String("\(type(of: error)): \(error)".prefix(2_048))
    return ProjectSecretRedactor.redact(value).text
  }
}
