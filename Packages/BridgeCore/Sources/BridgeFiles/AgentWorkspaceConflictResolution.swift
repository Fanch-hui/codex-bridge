import BridgeSecurity
import Foundation

extension AgentWorkspaceStore {
  public func resolveConflicts(
    id: String, resolutions: [AgentWorkspaceConflictResolution], requestID: String
  ) throws -> AgentWorkspaceResolutionResult {
    try validateIdentifier(id)
    try validateIdentifier(requestID)
    guard activeIDs.insert(id).inserted else { throw AgentWorkspaceError.workspaceBusy }
    defer { activeIDs.remove(id) }
    guard let snapshot = try snapshot(id: id) else {
      throw AgentWorkspaceError.workspaceUnavailable
    }
    if FileManager.default.fileExists(atPath: resolutionArchiveURL(id, requestID).path) {
      let archived = try readJSON(
        AgentWorkspaceResolutionJournal.self, id: id, name: "conflicts/\(requestID).json")
      try validateReplay(resolutions, id: id, requestID: requestID, journal: archived)
      return resolutionResult(archived)
    }
    guard !FileManager.default.fileExists(atPath: journalURL(id).path),
      !FileManager.default.fileExists(atPath: synchronizationJournalURL(id).path),
      !FileManager.default.fileExists(atPath: conflictRepairJournalURL(id).path)
    else {
      throw AgentWorkspaceError.recoveryRequired([])
    }
    let manifest = try readManifest(id: id)
    if FileManager.default.fileExists(atPath: resolutionJournalURL(id).path) {
      let journal = try readJSON(
        AgentWorkspaceResolutionJournal.self, id: id, name: "conflict-resolution-journal.json")
      try validateReplay(resolutions, id: id, requestID: requestID, journal: journal)
      return try finishResolution(journal, snapshot: snapshot, manifest: manifest)
    }
    let entries = try resolutionEntries(resolutions, snapshot: snapshot, manifest: manifest)
    let journal = AgentWorkspaceResolutionJournal(
      id: id, revision: manifest.revision, archiveID: requestID, entries: entries)
    try writeJSON(journal, to: resolutionJournalURL(id))
    return try commitResolution(journal, snapshot: snapshot, manifest: manifest)
  }

  public func recoverConflictResolution(id: String) throws -> AgentWorkspaceResolutionResult? {
    try validateIdentifier(id)
    guard activeIDs.insert(id).inserted else { throw AgentWorkspaceError.workspaceBusy }
    defer { activeIDs.remove(id) }
    let url = resolutionJournalURL(id)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    guard let snapshot = try snapshot(id: id) else {
      throw AgentWorkspaceError.workspaceUnavailable
    }
    let journal = try readJSON(
      AgentWorkspaceResolutionJournal.self, id: id, name: "conflict-resolution-journal.json")
    guard journal.id == id else { throw AgentWorkspaceError.invalidStorage }
    let manifest = try readManifest(id: id)
    return try finishResolution(journal, snapshot: snapshot, manifest: manifest)
  }

  private func finishResolution(
    _ journal: AgentWorkspaceResolutionJournal, snapshot: AgentWorkspaceSnapshot,
    manifest: AgentWorkspaceManifest
  ) throws -> AgentWorkspaceResolutionResult {
    if manifest.revision == journal.revision + 1 {
      try archiveResolution(journal)
      return resolutionResult(journal)
    }
    guard manifest.revision == journal.revision else { throw AgentWorkspaceError.invalidStorage }
    return try commitResolution(journal, snapshot: snapshot, manifest: manifest)
  }

  private func validateReplay(
    _ resolutions: [AgentWorkspaceConflictResolution], id: String, requestID: String,
    journal: AgentWorkspaceResolutionJournal
  ) throws {
    guard journal.id == id, journal.archiveID == requestID,
      resolutions.count == journal.entries.count, !resolutions.isEmpty
    else { throw AgentWorkspaceError.invalidResolution(requestID) }
    var expected: [String: AgentWorkspaceConflictResolution] = [:]
    var seen = Set<String>()
    for resolution in resolutions {
      let path = try SecureRelativePath(resolution.relativePath)
      guard path.value == resolution.relativePath, seen.insert(path.value).inserted else {
        throw AgentWorkspaceError.invalidResolution(resolution.relativePath)
      }
      expected[path.value] = resolution
    }
    for entry in journal.entries {
      guard let resolution = expected[entry.path],
        resolution.expectedSHA256
          == entry.selected.map({ SecureFileRevision.digest(of: $0).sha256 })
      else { throw AgentWorkspaceError.invalidResolution(entry.path) }
    }
  }

  private func resolutionResult(_ journal: AgentWorkspaceResolutionJournal)
    -> AgentWorkspaceResolutionResult
  {
    AgentWorkspaceResolutionResult(
      resolvedPaths: journal.entries.map(\.path), revision: journal.revision + 1,
      archiveID: journal.archiveID)
  }

  private func resolutionEntries(
    _ resolutions: [AgentWorkspaceConflictResolution], snapshot: AgentWorkspaceSnapshot,
    manifest: AgentWorkspaceManifest
  ) throws -> [AgentWorkspaceResolutionEntry] {
    guard !resolutions.isEmpty else { throw AgentWorkspaceError.invalidResolution("") }
    let policy = ProjectFilePolicy(forbiddenPatterns: manifest.forbiddenPatterns)
    let project = ProjectPathResolver(root: snapshot.projectRoot)
    let workspace = ProjectPathResolver(root: snapshot.workspaceRoot)
    let baseline = ProjectPathResolver(root: try baselineRoot(manifest))
    let pending = manifest.pendingConflicts ?? [:]
    var seen = Set<String>()
    var entries: [AgentWorkspaceResolutionEntry] = []
    var totalBytes = 0
    for resolution in resolutions {
      let path = try SecureRelativePath(resolution.relativePath)
      guard path.value == resolution.relativePath, policy.allows(path),
        seen.insert(path.value).inserted, let conflict = pending[path.value]
      else { throw AgentWorkspaceError.invalidResolution(resolution.relativePath) }
      let selected = try writer.readContent(relativePath: path, through: project)
      try AgentWorkspaceInventory.validateContent(selected, path: path.value)
      guard selected.map({ SecureFileRevision.digest(of: $0).sha256 }) == resolution.expectedSHA256,
        try writer.readContent(relativePath: path, through: workspace) == conflict.workspace,
        try writer.readContent(relativePath: path, through: baseline) == conflict.baseline
      else { throw AgentWorkspaceError.revisionConflict(path.value) }
      if conflict.workspace != nil {
        guard
          try AgentWorkspaceInventory.mode(at: snapshot.workspaceRoot, path: path.value)
            == conflict.workspaceMode
        else { throw AgentWorkspaceError.revisionConflict(path.value) }
      }
      let mode =
        selected == nil
        ? nil
        : try AgentWorkspaceInventory.mode(
          at: snapshot.projectRoot, path: path.value)
      let size =
        (selected?.count ?? 0) + (conflict.baseline?.count ?? 0)
        + (conflict.workspace?.count ?? 0) + (conflict.main?.count ?? 0)
      guard totalBytes <= 64 * 1_024 * 1_024 - size else {
        throw AgentWorkspaceError.resourceLimit
      }
      totalBytes += size
      entries.append(
        AgentWorkspaceResolutionEntry(
          path: path.value, conflict: conflict, selected: selected, selectedMode: mode))
    }
    return entries.sorted { $0.path < $1.path }
  }

  private func commitResolution(
    _ journal: AgentWorkspaceResolutionJournal, snapshot: AgentWorkspaceSnapshot,
    manifest initialManifest: AgentWorkspaceManifest
  ) throws -> AgentWorkspaceResolutionResult {
    let project = ProjectPathResolver(root: snapshot.projectRoot)
    let workspace = ProjectPathResolver(root: snapshot.workspaceRoot)
    let baseline = ProjectPathResolver(root: try baselineRoot(initialManifest))
    do {
      for entry in journal.entries {
        let path = try SecureRelativePath(entry.path)
        guard try writer.readContent(relativePath: path, through: project) == entry.selected else {
          throw AgentWorkspaceError.revisionConflict(entry.path)
        }
        if entry.selected != nil {
          guard
            try AgentWorkspaceInventory.mode(at: snapshot.projectRoot, path: entry.path)
              == entry.selectedMode
          else { throw AgentWorkspaceError.revisionConflict(entry.path) }
        }
        try applyValue(
          entry.selected, previous: entry.conflict.workspace, path: path, resolver: workspace)
        if let mode = entry.selectedMode {
          try AgentWorkspaceInventory.setMode(mode, at: snapshot.workspaceRoot, path: entry.path)
        }
        try applyValue(
          entry.selected, previous: entry.conflict.baseline, path: path, resolver: baseline)
      }
      var manifest = initialManifest
      for entry in journal.entries {
        guard manifest.pendingConflicts?[entry.path] == entry.conflict else {
          throw AgentWorkspaceError.invalidStorage
        }
        manifest.pendingConflicts?.removeValue(forKey: entry.path)
        manifest.modes[entry.path] = entry.selectedMode
      }
      manifest.revision += 1
      try writeManifest(manifest)
      try archiveResolution(journal)
      return AgentWorkspaceResolutionResult(
        resolvedPaths: journal.entries.map(\.path), revision: manifest.revision,
        archiveID: journal.archiveID)
    } catch {
      throw AgentWorkspaceError.recoveryRequired(journal.entries.map(\.path))
    }
  }

  private func archiveResolution(_ journal: AgentWorkspaceResolutionJournal) throws {
    try validateIdentifier(journal.archiveID)
    let folder = workspaceDirectory(journal.id).appendingPathComponent(
      "conflicts", isDirectory: true)
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let metadata = try FileSystemEntryMetadata(at: folder)
    guard metadata.isDirectory, !metadata.isSymbolicLink else {
      throw AgentWorkspaceError.invalidStorage
    }
    let target = resolutionArchiveURL(journal.id, journal.archiveID)
    try FileManager.default.moveItem(at: resolutionJournalURL(journal.id), to: target)
  }

  private func resolutionArchiveURL(_ id: String, _ requestID: String) -> URL {
    workspaceDirectory(id).appendingPathComponent("conflicts", isDirectory: true)
      .appendingPathComponent("\(requestID).json")
  }
}
