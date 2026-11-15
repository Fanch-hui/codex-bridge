import BridgeSecurity
import Foundation

extension AgentWorkspaceStore {
  private static let reclaimInspectionLimit = 16
  private static let reclaimingMarker = "~reclaiming~"
  /// Journals, candidates and unknown files fall outside this set, so their presence blocks reclaiming.
  private static let reclaimableStorage: Set<String> = [
    "baseline", "workspace", "runtime", "manifest.json", "git-template", "conflicts", "candidates",
  ]

  /// Frees managed slots by deleting merged, idle workspaces, least recently used first.
  ///
  /// `isIdle` is the caller's word that no agent can still run in the workspace; the store itself
  /// verifies that nothing unmerged is left on disk before anything is deleted.
  public func reclaimMergedWorkspaces(
    count: Int = 1, isIdle: @Sendable (String) async -> Bool
  ) async throws -> [String] {
    _ = try ensureManagementRoot()
    removeInterruptedReclamations()
    var reclaimed: [String] = []
    for id in try reclaimCandidates().prefix(Self.reclaimInspectionLimit) {
      guard reclaimed.count < count else { break }
      try Task.checkCancellation()
      guard await isIdle(id), reclaimIfSafe(id: id) else { continue }
      reclaimed.append(id)
    }
    return reclaimed
  }

  /// Deletes archived conflict versions once every conflict is resolved and merged.
  @discardableResult
  public func discardResolvedConflictArchives(id: String) throws -> Bool {
    try validateIdentifier(id)
    guard activeIDs.insert(id).inserted else { throw AgentWorkspaceError.workspaceBusy }
    defer { activeIDs.remove(id) }
    guard try snapshot(id: id) != nil else { return false }
    let manifest = try readManifest(id: id)
    guard manifest.pendingConflicts?.isEmpty ?? true, manifest.repairMarkers?.isEmpty ?? true,
      !hasJournal(id)
    else { return false }
    let folder = workspaceDirectory(id)
    guard try FileManager.default.contentsOfDirectory(atPath: folder.path).contains("conflicts")
    else { return false }
    let archive = folder.appendingPathComponent("conflicts", isDirectory: true)
    let metadata = try FileSystemEntryMetadata(at: archive)
    guard metadata.isDirectory, !metadata.isSymbolicLink else {
      throw AgentWorkspaceError.invalidStorage
    }
    try FileManager.default.removeItem(at: archive)
    return true
  }

  /// Valid workspace folders, oldest manifest write first.
  private func reclaimCandidates() throws -> [String] {
    var dated: [(id: String, modified: Date)] = []
    for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
      guard (try? validateIdentifier(name)) != nil, !activeIDs.contains(name) else { continue }
      let manifest = workspaceDirectory(name).appendingPathComponent("manifest.json")
      // Entries without a readable manifest are not workspaces this store can vouch for.
      guard let attributes = try? FileManager.default.attributesOfItem(atPath: manifest.path),
        let modified = attributes[.modificationDate] as? Date
      else { continue }
      dated.append((name, modified))
    }
    return dated.sorted { ($0.modified, $0.id) < ($1.modified, $1.id) }.map(\.id)
  }

  /// Synchronous, so no other store operation can interleave between the checks and the removal.
  private func reclaimIfSafe(id: String) -> Bool {
    guard !activeIDs.contains(id), isSafeToReclaim(id: id) else { return false }
    let tombstone = directory.appendingPathComponent(
      id + Self.reclaimingMarker + UUID().uuidString, isDirectory: true)
    do { try FileManager.default.moveItem(at: workspaceDirectory(id), to: tombstone) } catch {
      return false
    }
    // The workspace already left the managed namespace; leftovers are retried by the next reclaim.
    try? FileManager.default.removeItem(at: tombstone)
    return true
  }

  private func isSafeToReclaim(id: String) -> Bool {
    do {
      guard let snapshot = try snapshot(id: id), try storageAllowsReclaim(id: id) else {
        return false
      }
      let manifest = try readManifest(id: id)
      guard manifest.pendingConflicts?.isEmpty ?? true, manifest.repairMarkers?.isEmpty ?? true,
        !hasJournal(id)
      else { return false }
      return try hasNoUnmergedContent(snapshot: snapshot, manifest: manifest)
    } catch {
      // Anything unreadable or unexpected keeps the workspace; only a clean verdict deletes it.
      return false
    }
  }

  private func hasJournal(_ id: String) -> Bool {
    [
      journalURL(id), resolutionJournalURL(id), synchronizationJournalURL(id),
      conflictRepairJournalURL(id),
    ].contains { FileManager.default.fileExists(atPath: $0.path) }
  }

  private func storageAllowsReclaim(id: String) throws -> Bool {
    let folder = workspaceDirectory(id)
    let names = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
    guard names.isSubset(of: Self.reclaimableStorage) else { return false }
    for name in ["candidates", "conflicts"] where names.contains(name) {
      let url = folder.appendingPathComponent(name, isDirectory: true)
      let metadata = try FileSystemEntryMetadata(at: url)
      guard metadata.isDirectory, !metadata.isSymbolicLink else { return false }
    }
    guard names.contains("candidates") else { return true }
    // A retained validation candidate still references this workspace.
    return try FileManager.default.contentsOfDirectory(
      atPath: folder.appendingPathComponent("candidates").path
    ).isEmpty
  }

  /// Everything the workspace holds is already in the baseline, so deleting it loses nothing.
  private func hasNoUnmergedContent(
    snapshot: AgentWorkspaceSnapshot, manifest: AgentWorkspaceManifest
  ) throws -> Bool {
    let policy = ProjectFilePolicy(forbiddenPatterns: manifest.forbiddenPatterns)
    let baseFiles = try fingerprint(root: baselineRoot(manifest), policy: policy)
    let childFiles = try fingerprint(root: snapshot.workspaceRoot, policy: policy)
    guard Set(baseFiles.keys) == Set(childFiles.keys) else { return false }
    for (path, base) in baseFiles {
      guard let child = childFiles[path], child.sha256 == base.sha256,
        child.mode == manifest.modes[path]
      else { return false }
    }
    // Files under excluded names are never merged, so any of them is output that would be lost.
    return try AgentWorkspaceInventory(root: snapshot.workspaceRoot, policy: policy)
      .excludedEntries(limit: 1).isEmpty
  }

  private func removeInterruptedReclamations() {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
      return
    }
    for name in names where name.contains(Self.reclaimingMarker) {
      let url = directory.appendingPathComponent(name)
      guard let metadata = try? FileSystemEntryMetadata(at: url), metadata.isDirectory,
        !metadata.isSymbolicLink
      else { continue }
      try? FileManager.default.removeItem(at: url)
    }
  }
}
