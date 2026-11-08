import BridgeSecurity
import Foundation

private struct AgentWorkspaceRepairEntry: Codable, Sendable {
  let path: String
  let conflict: AgentWorkspacePendingConflict
  let main: Data?
  let mainMode: Int?
  let marker: String
  let markedContent: Data
  let markedMode: Int
}

private struct AgentWorkspaceRepairJournal: Codable, Sendable {
  let id: String
  let revision: Int
  let archiveID: String
  let entries: [AgentWorkspaceRepairEntry]
}

extension AgentWorkspaceStore {
  public func canRepairConflicts(id: String) throws -> Bool {
    try validateIdentifier(id)
    guard let snapshot = try snapshot(id: id) else {
      throw AgentWorkspaceError.workspaceUnavailable
    }
    let manifest = try readManifest(id: id)
    let pending = manifest.pendingConflicts ?? [:]
    if pending.isEmpty { return !(manifest.repairMarkers?.isEmpty ?? true) }
    let project = ProjectPathResolver(root: snapshot.projectRoot)
    for (value, conflict) in pending {
      let current = try writer.readContent(
        relativePath: SecureRelativePath(value), through: project)
      guard Self.repairableText(conflict.baseline), Self.repairableText(conflict.workspace),
        Self.repairableText(current),
        (conflict.baseline?.count ?? 0) + (conflict.workspace?.count ?? 0)
          + (current?.count ?? 0) + 1_024 <= AgentWorkspaceInventory.maximumFileBytes
      else { return false }
    }
    return true
  }

  /// Rebase conflicted paths in the idle child and archive every original version.
  public func prepareConflictRepair(id: String) throws -> [String] {
    try validateIdentifier(id)
    guard activeIDs.insert(id).inserted else { throw AgentWorkspaceError.workspaceBusy }
    defer { activeIDs.remove(id) }
    guard let snapshot = try snapshot(id: id) else {
      throw AgentWorkspaceError.workspaceUnavailable
    }
    guard !FileManager.default.fileExists(atPath: journalURL(id).path),
      !FileManager.default.fileExists(atPath: resolutionJournalURL(id).path),
      !FileManager.default.fileExists(atPath: synchronizationJournalURL(id).path)
    else { throw AgentWorkspaceError.recoveryRequired([]) }
    let url = conflictRepairJournalURL(id)
    if FileManager.default.fileExists(atPath: url.path) {
      let journal = try readJSON(
        AgentWorkspaceRepairJournal.self, id: id, name: "conflict-repair-journal.json")
      guard journal.id == id else { throw AgentWorkspaceError.invalidStorage }
      try commitConflictRepair(journal, snapshot: snapshot, manifest: readManifest(id: id))
    }
    let manifest = try readManifest(id: id)
    let pending = manifest.pendingConflicts ?? [:]
    let existing = Set(manifest.repairMarkers?.keys.map { $0 } ?? [])
    let unprepared = pending.filter { !existing.contains($0.key) }
    guard !unprepared.isEmpty else { return existing.sorted() }
    let entries = try repairEntries(unprepared, snapshot: snapshot, manifest: manifest)
    let journal = AgentWorkspaceRepairJournal(
      id: id, revision: manifest.revision, archiveID: UUID().uuidString.lowercased(),
      entries: entries)
    try writeJSON(journal, to: url)
    try commitConflictRepair(journal, snapshot: snapshot, manifest: manifest)
    return existing.union(entries.map(\.path)).sorted()
  }

  func conflictRepairJournalURL(_ id: String) -> URL {
    workspaceDirectory(id).appendingPathComponent("conflict-repair-journal.json")
  }

  private func repairEntries(
    _ conflicts: [String: AgentWorkspacePendingConflict], snapshot: AgentWorkspaceSnapshot,
    manifest: AgentWorkspaceManifest
  ) throws -> [AgentWorkspaceRepairEntry] {
    let project = ProjectPathResolver(root: snapshot.projectRoot)
    let child = ProjectPathResolver(root: snapshot.workspaceRoot)
    let baseline = ProjectPathResolver(root: try baselineRoot(manifest))
    let policy = ProjectFilePolicy(forbiddenPatterns: manifest.forbiddenPatterns)
    var entries: [AgentWorkspaceRepairEntry] = []
    var totalBytes = 0
    for value in conflicts.keys.sorted() {
      guard let conflict = conflicts[value] else { throw AgentWorkspaceError.invalidStorage }
      let path = try SecureRelativePath(value)
      guard policy.allows(path),
        try writer.readContent(relativePath: path, through: child) == conflict.workspace,
        try writer.readContent(relativePath: path, through: baseline) == conflict.baseline
      else { throw AgentWorkspaceError.revisionConflict(value) }
      if conflict.workspace != nil {
        guard
          try AgentWorkspaceInventory.mode(at: snapshot.workspaceRoot, path: value)
            == conflict.workspaceMode
        else { throw AgentWorkspaceError.revisionConflict(value) }
      }
      let main = try writer.readContent(relativePath: path, through: project)
      try AgentWorkspaceInventory.validateContent(main, path: value)
      let mode =
        main == nil ? nil : try AgentWorkspaceInventory.mode(at: snapshot.projectRoot, path: value)
      let marker = "BRIDGE_CONFLICT_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
      let marked = try Self.markedConflict(
        conflict: conflict, main: main, marker: marker, path: value)
      let size =
        (conflict.baseline?.count ?? 0) + (conflict.workspace?.count ?? 0)
        + (conflict.main?.count ?? 0) + (main?.count ?? 0) + marked.count
      guard totalBytes <= 64 * 1_024 * 1_024 - size else { throw AgentWorkspaceError.resourceLimit }
      totalBytes += size
      entries.append(
        AgentWorkspaceRepairEntry(
          path: value, conflict: conflict, main: main, mainMode: mode, marker: marker,
          markedContent: marked, markedMode: conflict.workspaceMode ?? mode ?? 0o644))
    }
    return entries
  }

  private static func repairableText(_ value: Data?) -> Bool {
    guard let value else { return true }
    return !value.contains(0) && String(data: value, encoding: .utf8) != nil
  }

  private static func markedConflict(
    conflict: AgentWorkspacePendingConflict, main: Data?, marker: String, path: String
  ) throws -> Data {
    guard repairableText(conflict.baseline), repairableText(conflict.workspace),
      repairableText(main)
    else { throw AgentWorkspaceError.unsupportedEntry(path) }
    func version(_ value: Data?) -> String {
      guard let value, let text = String(data: value, encoding: .utf8) else { return "" }
      return text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
    }
    let text =
      "<<<<<<< \(marker) MAIN\(main == nil ? " (deleted)" : "")\n"
      + version(main) + "||||||| \(marker) BASE\(conflict.baseline == nil ? " (deleted)" : "")\n"
      + version(conflict.baseline) + "======= \(marker)\n" + version(conflict.workspace)
      + ">>>>>>> \(marker) CHILD\(conflict.workspace == nil ? " (deleted)" : "")\n"
    let data = Data(text.utf8)
    guard data.count <= AgentWorkspaceInventory.maximumFileBytes else {
      throw AgentWorkspaceError.resourceLimit
    }
    return data
  }

  private func commitConflictRepair(
    _ journal: AgentWorkspaceRepairJournal, snapshot: AgentWorkspaceSnapshot,
    manifest initialManifest: AgentWorkspaceManifest
  ) throws {
    guard
      initialManifest.revision == journal.revision
        || initialManifest.revision == journal.revision + 1
    else { throw AgentWorkspaceError.invalidStorage }
    let child = ProjectPathResolver(root: snapshot.workspaceRoot)
    let baseline = ProjectPathResolver(root: try baselineRoot(initialManifest))
    for entry in journal.entries {
      let path = try SecureRelativePath(entry.path)
      let childValue = try writer.readContent(relativePath: path, through: child)
      let baseValue = try writer.readContent(relativePath: path, through: baseline)
      guard childValue == entry.conflict.workspace || childValue == entry.markedContent,
        baseValue == entry.conflict.baseline || baseValue == entry.main
      else { throw AgentWorkspaceError.recoveryRequired([entry.path]) }
      if initialManifest.revision == journal.revision + 1,
        childValue != entry.markedContent || baseValue != entry.main
      {
        throw AgentWorkspaceError.recoveryRequired([entry.path])
      }
    }
    if initialManifest.revision == journal.revision {
      for entry in journal.entries {
        let path = try SecureRelativePath(entry.path)
        try applyValue(
          entry.markedContent, previous: entry.conflict.workspace, path: path, resolver: child)
        try AgentWorkspaceInventory.setMode(
          entry.markedMode, at: snapshot.workspaceRoot, path: entry.path)
        try applyValue(
          entry.main, previous: entry.conflict.baseline, path: path, resolver: baseline)
      }
      var manifest = initialManifest
      for entry in journal.entries {
        guard manifest.pendingConflicts?[entry.path] == entry.conflict else {
          throw AgentWorkspaceError.invalidStorage
        }
        manifest.pendingConflicts?.removeValue(forKey: entry.path)
        manifest.modes[entry.path] = entry.mainMode
        if manifest.repairMarkers == nil { manifest.repairMarkers = [:] }
        manifest.repairMarkers?[entry.path] = entry.marker
      }
      manifest.revision += 1
      try writeManifest(manifest)
    }
    let folder = workspaceDirectory(journal.id).appendingPathComponent(
      "conflicts", isDirectory: true)
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let metadata = try FileSystemEntryMetadata(at: folder)
    guard metadata.isDirectory, !metadata.isSymbolicLink else {
      throw AgentWorkspaceError.invalidStorage
    }
    try validateIdentifier(journal.archiveID)
    let target = folder.appendingPathComponent("repair-" + journal.archiveID + ".json")
    try FileManager.default.moveItem(at: conflictRepairJournalURL(journal.id), to: target)
  }
}
