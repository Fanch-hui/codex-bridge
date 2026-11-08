import BridgeSecurity
import Foundation

struct AgentWorkspaceSynchronizationEntry: Codable, Sendable {
  let path: String
  let before: Data?
  let after: Data?
  let beforeMode: Int?
  let afterMode: Int?
}

struct AgentWorkspaceSynchronizationJournal: Codable, Sendable {
  let id: String
  let revision: Int
  let entries: [AgentWorkspaceSynchronizationEntry]
}

extension AgentWorkspaceStore {
  /// Refresh an idle, fully merged workspace while retaining its directory identity.
  public func synchronize(id: String) throws -> [String] {
    try validateIdentifier(id)
    guard activeIDs.insert(id).inserted else { throw AgentWorkspaceError.workspaceBusy }
    defer { activeIDs.remove(id) }
    guard let snapshot = try snapshot(id: id) else {
      throw AgentWorkspaceError.workspaceUnavailable
    }
    guard !FileManager.default.fileExists(atPath: journalURL(id).path),
      !FileManager.default.fileExists(atPath: resolutionJournalURL(id).path),
      !FileManager.default.fileExists(atPath: conflictRepairJournalURL(id).path)
    else { throw AgentWorkspaceError.recoveryRequired([]) }

    try recoverSynchronization(snapshot: snapshot)
    let manifest = try readManifest(id: id)
    guard manifest.pendingConflicts?.isEmpty ?? true else {
      throw AgentWorkspaceError.mergeConflict(manifest.pendingConflicts?.keys.sorted() ?? [])
    }
    guard manifest.repairMarkers?.isEmpty ?? true else {
      throw AgentWorkspaceError.mergeConflict(manifest.repairMarkers?.keys.sorted() ?? [])
    }
    let entries = try synchronizationEntries(snapshot: snapshot, manifest: manifest)
    guard !entries.isEmpty else { return [] }
    let journal = AgentWorkspaceSynchronizationJournal(
      id: id, revision: manifest.revision, entries: entries)
    try writeJSON(journal, to: synchronizationJournalURL(id))
    try commitSynchronization(journal, snapshot: snapshot, manifest: manifest)
    return entries.map(\.path)
  }

  func synchronizationJournalURL(_ id: String) -> URL {
    workspaceDirectory(id).appendingPathComponent("synchronization-journal.json")
  }

  private func synchronizationEntries(
    snapshot: AgentWorkspaceSnapshot, manifest: AgentWorkspaceManifest
  ) throws -> [AgentWorkspaceSynchronizationEntry] {
    let baseline = try baselineRoot(manifest)
    let policy = ProjectFilePolicy(forbiddenPatterns: manifest.forbiddenPatterns)
    let baseFiles = try fingerprint(root: baseline, policy: policy)
    let childFiles = try fingerprint(root: snapshot.workspaceRoot, policy: policy)
    let projectFiles = try fingerprint(root: snapshot.projectRoot, policy: policy)
    guard Set(baseFiles.keys) == Set(childFiles.keys) else {
      throw AgentWorkspaceError.revisionConflict("")
    }
    for (path, base) in baseFiles {
      guard let child = childFiles[path], child.sha256 == base.sha256,
        child.mode == manifest.modes[path]
      else { throw AgentWorkspaceError.revisionConflict(path) }
    }

    let baseResolver = ProjectPathResolver(root: baseline)
    let projectResolver = ProjectPathResolver(root: snapshot.projectRoot)
    let paths = Set(baseFiles.keys).union(projectFiles.keys).sorted()
    var entries: [AgentWorkspaceSynchronizationEntry] = []
    var totalBytes = 0
    for value in paths {
      let before = baseFiles[value]
      let after = projectFiles[value]
      let beforeMode = childFiles[value]?.mode
      guard before?.sha256 != after?.sha256 || beforeMode != after?.mode else { continue }
      let path = try SecureRelativePath(value)
      let oldData = try writer.readContent(relativePath: path, through: baseResolver)
      let newData = try writer.readContent(relativePath: path, through: projectResolver)
      guard oldData.map({ SecureFileRevision.digest(of: $0).sha256 }) == before?.sha256,
        newData.map({ SecureFileRevision.digest(of: $0).sha256 }) == after?.sha256
      else { throw AgentWorkspaceError.revisionConflict(value) }
      try AgentWorkspaceInventory.validateContent(newData, path: value)
      let size = (oldData?.count ?? 0) + (newData?.count ?? 0)
      guard totalBytes <= 64 * 1_024 * 1_024 - size else {
        throw AgentWorkspaceError.resourceLimit
      }
      totalBytes += size
      entries.append(
        AgentWorkspaceSynchronizationEntry(
          path: value, before: oldData, after: newData, beforeMode: beforeMode,
          afterMode: after?.mode))
    }
    guard try fingerprint(root: baseline, policy: policy) == baseFiles,
      try fingerprint(root: snapshot.workspaceRoot, policy: policy) == childFiles,
      try fingerprint(root: snapshot.projectRoot, policy: policy) == projectFiles
    else { throw AgentWorkspaceError.revisionConflict("") }
    return entries
  }

  private func recoverSynchronization(snapshot: AgentWorkspaceSnapshot) throws {
    let url = synchronizationJournalURL(snapshot.id)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    let journal = try readJSON(
      AgentWorkspaceSynchronizationJournal.self, id: snapshot.id,
      name: "synchronization-journal.json")
    guard journal.id == snapshot.id else { throw AgentWorkspaceError.invalidStorage }
    try commitSynchronization(journal, snapshot: snapshot, manifest: readManifest(id: snapshot.id))
  }

  private func commitSynchronization(
    _ journal: AgentWorkspaceSynchronizationJournal, snapshot: AgentWorkspaceSnapshot,
    manifest initialManifest: AgentWorkspaceManifest
  ) throws {
    guard
      initialManifest.revision == journal.revision
        || initialManifest.revision == journal.revision + 1
    else { throw AgentWorkspaceError.invalidStorage }
    let baseline = ProjectPathResolver(root: try baselineRoot(initialManifest))
    let child = ProjectPathResolver(root: snapshot.workspaceRoot)
    var seen = Set<String>()
    let policy = ProjectFilePolicy(forbiddenPatterns: initialManifest.forbiddenPatterns)
    for entry in journal.entries {
      let path = try SecureRelativePath(entry.path)
      guard seen.insert(entry.path).inserted, policy.allows(path) else {
        throw AgentWorkspaceError.invalidStorage
      }
      let childValue = try writer.readContent(relativePath: path, through: child)
      let baseValue = try writer.readContent(relativePath: path, through: baseline)
      if initialManifest.revision == journal.revision + 1,
        childValue != entry.after || baseValue != entry.after
      {
        throw AgentWorkspaceError.recoveryRequired([entry.path])
      }
      guard childValue == entry.before || childValue == entry.after,
        baseValue == entry.before || baseValue == entry.after
      else { throw AgentWorkspaceError.recoveryRequired([entry.path]) }
      if childValue != nil {
        let mode = try AgentWorkspaceInventory.mode(at: snapshot.workspaceRoot, path: entry.path)
        if initialManifest.revision == journal.revision + 1, mode != entry.afterMode {
          throw AgentWorkspaceError.recoveryRequired([entry.path])
        }
        guard mode == entry.beforeMode || mode == entry.afterMode else {
          throw AgentWorkspaceError.recoveryRequired([entry.path])
        }
      }
    }
    if initialManifest.revision == journal.revision {
      for entry in journal.entries {
        let path = try SecureRelativePath(entry.path)
        try applyValue(entry.after, previous: entry.before, path: path, resolver: child)
        if let mode = entry.afterMode {
          try AgentWorkspaceInventory.setMode(mode, at: snapshot.workspaceRoot, path: entry.path)
        }
        try applyValue(entry.after, previous: entry.before, path: path, resolver: baseline)
      }
      var manifest = initialManifest
      for entry in journal.entries { manifest.modes[entry.path] = entry.afterMode }
      manifest.revision += 1
      try writeManifest(manifest)
    }
    try FileManager.default.removeItem(at: synchronizationJournalURL(journal.id))
  }
}
