import BridgeSecurity
import Foundation

extension AgentWorkspaceStore {
  public func applyMerge(plan: AgentWorkspaceMergePlan) throws -> AgentWorkspaceMergeResult {
    try validateIdentifier(plan.id)
    guard activeIDs.insert(plan.id).inserted else { throw AgentWorkspaceError.workspaceBusy }
    defer { activeIDs.remove(plan.id) }
    guard plan.conflicts.isEmpty else { throw AgentWorkspaceError.mergeConflict(plan.conflicts) }
    guard let snapshot = try snapshot(id: plan.id) else {
      throw AgentWorkspaceError.workspaceUnavailable
    }
    guard snapshot.revision == plan.revision else { throw AgentWorkspaceError.revisionConflict("") }
    let url = journalURL(plan.id)
    guard !FileManager.default.fileExists(atPath: url.path),
      !FileManager.default.fileExists(atPath: resolutionJournalURL(plan.id).path),
      !FileManager.default.fileExists(atPath: synchronizationJournalURL(plan.id).path),
      !FileManager.default.fileExists(atPath: conflictRepairJournalURL(plan.id).path)
    else {
      throw AgentWorkspaceError.recoveryRequired([])
    }
    if plan.changes.isEmpty {
      return AgentWorkspaceMergeResult(changedPaths: [], revision: snapshot.revision)
    }
    let manifest = try readManifest(id: plan.id)
    if let conflicts = manifest.pendingConflicts, !conflicts.isEmpty {
      throw AgentWorkspaceError.mergeConflict(conflicts.keys.sorted())
    }
    try validateChanges(plan.changes, snapshot: snapshot, manifest: manifest)
    let journal = AgentWorkspaceJournal(id: plan.id, revision: plan.revision, changes: plan.changes)
    try writeJSON(journal, to: url)
    return try commit(journal, snapshot: snapshot, manifest: manifest)
  }

  public func recoverMerge(id: String) throws -> AgentWorkspaceMergeResult? {
    try validateIdentifier(id)
    guard activeIDs.insert(id).inserted else { throw AgentWorkspaceError.workspaceBusy }
    defer { activeIDs.remove(id) }
    let url = journalURL(id)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    guard let snapshot = try snapshot(id: id) else {
      throw AgentWorkspaceError.workspaceUnavailable
    }
    let journal = try readJSON(AgentWorkspaceJournal.self, id: id, name: "merge-journal.json")
    guard journal.id == id else { throw AgentWorkspaceError.invalidStorage }
    guard journal.phase == nil || journal.phase == "apply" else {
      throw AgentWorkspaceError.recoveryRequired(journal.changes.map(\.path))
    }
    let manifest = try readManifest(id: id)
    if manifest.revision == journal.revision + 1 {
      try FileManager.default.removeItem(at: url)
      return AgentWorkspaceMergeResult(
        changedPaths: journal.changes.map(\.path), revision: manifest.revision)
    }
    guard manifest.revision == journal.revision else { throw AgentWorkspaceError.invalidStorage }
    return try commit(journal, snapshot: snapshot, manifest: manifest)
  }

  func validateChanges(
    _ changes: [AgentWorkspaceChange], snapshot: AgentWorkspaceSnapshot,
    manifest: AgentWorkspaceManifest
  ) throws {
    let policy = ProjectFilePolicy(forbiddenPatterns: manifest.forbiddenPatterns)
    let roots = [snapshot.projectRoot, snapshot.workspaceRoot, try baselineRoot(manifest)]
    let resolvers = roots.map { ProjectPathResolver(root: $0) }
    var seen = Set<String>()
    for change in changes {
      let path = try SecureRelativePath(change.path)
      guard seen.insert(change.path).inserted, policy.allows(path) else {
        throw AgentWorkspaceError.invalidStorage
      }
      let expected = [change.before, change.workspace, change.baseline]
      for (resolver, value) in zip(resolvers, expected) {
        guard try writer.readContent(relativePath: path, through: resolver) == value else {
          throw AgentWorkspaceError.revisionConflict(change.path)
        }
      }
      if change.workspace != nil {
        guard
          try AgentWorkspaceInventory.mode(at: snapshot.workspaceRoot, path: change.path)
            == change.workspaceMode
        else { throw AgentWorkspaceError.revisionConflict(change.path) }
      }
      if let beforeMode = change.beforeMode {
        guard
          try AgentWorkspaceInventory.mode(at: snapshot.projectRoot, path: change.path)
            == beforeMode
        else { throw AgentWorkspaceError.revisionConflict(change.path) }
      }
    }
  }

  private func commit(
    _ journal: AgentWorkspaceJournal, snapshot: AgentWorkspaceSnapshot,
    manifest initialManifest: AgentWorkspaceManifest
  ) throws -> AgentWorkspaceMergeResult {
    let project = ProjectPathResolver(root: snapshot.projectRoot)
    let workspace = ProjectPathResolver(root: snapshot.workspaceRoot)
    let baseline = ProjectPathResolver(root: try baselineRoot(initialManifest))
    do {
      for change in journal.changes {
        let path = try SecureRelativePath(change.path)
        guard try writer.readContent(relativePath: path, through: workspace) == change.workspace
        else {
          throw AgentWorkspaceError.revisionConflict(change.path)
        }
        if let beforeMode = change.beforeMode,
          try writer.readContent(relativePath: path, through: project) != nil
        {
          guard
            try AgentWorkspaceInventory.mode(at: snapshot.projectRoot, path: change.path)
              == beforeMode
          else { throw AgentWorkspaceError.revisionConflict(change.path) }
        }
        try applyValue(change.after, previous: change.before, path: path, resolver: project)
      }
      for change in journal.changes {
        let path = try SecureRelativePath(change.path)
        try applyValue(change.workspace, previous: change.baseline, path: path, resolver: baseline)
      }
      var manifest = initialManifest
      for change in journal.changes {
        manifest.modes[change.path] = change.workspaceMode
      }
      manifest.revision += 1
      try writeManifest(manifest)
      try FileManager.default.removeItem(at: journalURL(journal.id))
      return AgentWorkspaceMergeResult(
        changedPaths: journal.changes.map(\.path), revision: manifest.revision)
    } catch {
      throw recordMergeFailure(error, journal: journal)
    }
  }

  func applyValue(
    _ value: Data?, previous: Data?, path: SecureRelativePath, resolver: ProjectPathResolver
  ) throws {
    let current = try writer.readContent(relativePath: path, through: resolver)
    if current == value { return }
    guard current == previous else { throw AgentWorkspaceError.revisionConflict(path.value) }
    if let value {
      _ = try writer.write(
        relativePath: path, through: resolver, mode: previous == nil ? .create : .replace,
        content: value, expectedSHA256: previous.map { SecureFileRevision.digest(of: $0).sha256 },
        createParents: true, allowsBinaryContent: true)
    } else if let previous {
      _ = try directoryMutation.apply(
        action: .deleteFile(expectedSHA256: SecureFileRevision.digest(of: previous).sha256),
        relativePath: path, destinationRelativePath: nil, through: resolver)
    }
  }
}
