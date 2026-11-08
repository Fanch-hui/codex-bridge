import BridgeSecurity
import Foundation

extension AgentWorkspaceStore {
  public func planMerge(id: String) throws -> AgentWorkspaceMergePlan {
    try validateIdentifier(id)
    guard !activeIDs.contains(id) else { throw AgentWorkspaceError.workspaceBusy }
    guard let snapshot = try snapshot(id: id) else {
      throw AgentWorkspaceError.workspaceUnavailable
    }
    guard !FileManager.default.fileExists(atPath: journalURL(id).path),
      !FileManager.default.fileExists(atPath: resolutionJournalURL(id).path),
      !FileManager.default.fileExists(atPath: synchronizationJournalURL(id).path),
      !FileManager.default.fileExists(atPath: conflictRepairJournalURL(id).path)
    else {
      throw AgentWorkspaceError.recoveryRequired([])
    }
    var manifest = try readManifest(id: id)
    let baseline = try baselineRoot(manifest)
    let policy = ProjectFilePolicy(forbiddenPatterns: manifest.forbiddenPatterns)
    let basePaths = try AgentWorkspaceInventory(root: baseline, policy: policy).paths()
    let workspacePaths = try AgentWorkspaceInventory(root: snapshot.workspaceRoot, policy: policy)
      .paths()
    let paths = Set(basePaths).union(workspacePaths).sorted()
    let pathSet = Set(paths)
    let baseResolver = ProjectPathResolver(root: baseline)
    let childResolver = ProjectPathResolver(root: snapshot.workspaceRoot)
    let projectResolver = ProjectPathResolver(root: snapshot.projectRoot)
    var changes: [AgentWorkspaceChange] = []
    var pending = manifest.pendingConflicts ?? [:]
    var conflictsChanged = false
    var unresolvedRepairs: [String] = []
    for path in manifest.repairMarkers.map({ Array($0.keys) }) ?? [] where !pathSet.contains(path) {
      if let marker = manifest.repairMarkers?[path], let conflict = pending[path],
        conflict.workspace?.range(of: Data(marker.utf8)) != nil
      {
        pending.removeValue(forKey: path)
      }
      manifest.repairMarkers?.removeValue(forKey: path)
      conflictsChanged = true
    }
    guard Set(pending.keys).isSubset(of: pathSet) else {
      throw AgentWorkspaceError.recoveryRequired(pending.keys.sorted())
    }
    var changeBytes = 0
    for conflict in pending.values {
      changeBytes +=
        (conflict.baseline?.count ?? 0) + (conflict.workspace?.count ?? 0)
        + (conflict.main?.count ?? 0)
      guard changeBytes <= 64 * 1_024 * 1_024 else { throw AgentWorkspaceError.resourceLimit }
    }

    for value in paths {
      try Task.checkCancellation()
      let path = try SecureRelativePath(value)
      let original = try writer.readContent(relativePath: path, through: baseResolver)
      let child = try writer.readContent(relativePath: path, through: childResolver)
      try AgentWorkspaceInventory.validateContent(child, path: value)
      let mode =
        child == nil
        ? nil : try AgentWorkspaceInventory.mode(at: snapshot.workspaceRoot, path: value)
      if let marker = manifest.repairMarkers?[value] {
        if let child, child.range(of: Data(marker.utf8)) != nil {
          if pending[value] == nil {
            let current = try writer.readContent(relativePath: path, through: projectResolver)
            try AgentWorkspaceInventory.validateContent(current, path: value)
            let size = (original?.count ?? 0) + child.count + (current?.count ?? 0)
            guard changeBytes <= 64 * 1_024 * 1_024 - size else {
              throw AgentWorkspaceError.resourceLimit
            }
            changeBytes += size
            pending[value] = AgentWorkspacePendingConflict(
              baseline: original, workspace: child, workspaceMode: mode, main: current)
            conflictsChanged = true
          }
          unresolvedRepairs.append(value)
          continue
        }
        if let conflict = pending[value],
          conflict.workspace?.range(of: Data(marker.utf8)) != nil
        {
          pending.removeValue(forKey: value)
        }
        manifest.repairMarkers?.removeValue(forKey: value)
        conflictsChanged = true
      }
      if let conflict = pending[value] {
        guard conflict.baseline == original, conflict.workspace == child,
          conflict.workspaceMode == mode
        else { throw AgentWorkspaceError.recoveryRequired([value]) }
        continue
      }
      let modeChanged =
        (mode != nil && manifest.modes[value] != nil && mode != manifest.modes[value])
        || (original == nil && (mode ?? 0) & 0o111 != 0)
      guard original != child || modeChanged else { continue }
      let current = try writer.readContent(relativePath: path, through: projectResolver)
      try AgentWorkspaceInventory.validateContent(current, path: value)
      let beforeMode =
        current == nil
        ? nil : try AgentWorkspaceInventory.mode(at: snapshot.projectRoot, path: value)
      let merged =
        modeChanged
        ? nil
        : AgentWorkspaceTextMerge.merge(
          base: original, current: current, other: child)
      guard let merged else {
        let size = (original?.count ?? 0) + (child?.count ?? 0) + (current?.count ?? 0)
        guard changeBytes <= 64 * 1_024 * 1_024 - size else {
          throw AgentWorkspaceError.resourceLimit
        }
        changeBytes += size
        pending[value] = AgentWorkspacePendingConflict(
          baseline: original, workspace: child, workspaceMode: mode, main: current)
        conflictsChanged = true
        continue
      }
      let size =
        (original?.count ?? 0) + (child?.count ?? 0)
        + (current?.count ?? 0) + (merged.value?.count ?? 0)
      guard changeBytes <= 64 * 1_024 * 1_024 - size else {
        throw AgentWorkspaceError.resourceLimit
      }
      changeBytes += size
      changes.append(
        AgentWorkspaceChange(
          path: value, before: current, after: merged.value, baseline: original,
          workspace: child, workspaceMode: mode, beforeMode: beforeMode))
    }
    if conflictsChanged {
      manifest.pendingConflicts = pending
      manifest.revision += 1
      try writeManifest(manifest)
    }
    return AgentWorkspaceMergePlan(
      id: id, revision: manifest.revision, changedPaths: changes.map(\.path),
      conflicts: Set(pending.keys).union(unresolvedRepairs).sorted(), changes: changes)
  }

  func baselineRoot(_ manifest: AgentWorkspaceManifest) throws -> RegisteredRoot {
    try privateRoot(
      at: workspaceDirectory(manifest.id).appendingPathComponent("baseline", isDirectory: true),
      identity: manifest.baselineIdentity)
  }

  func journalURL(_ id: String) -> URL {
    workspaceDirectory(id).appendingPathComponent("merge-journal.json")
  }

  func resolutionJournalURL(_ id: String) -> URL {
    workspaceDirectory(id).appendingPathComponent("conflict-resolution-journal.json")
  }
}

enum AgentWorkspaceTextMerge {
  struct Result {
    let value: Data?
  }

  private struct Edit: Equatable {
    let start: Int
    let end: Int
    let lines: [String]
  }

  static func merge(base: Data?, current: Data?, other: Data?) -> Result? {
    if current == base { return Result(value: other) }
    if other == base || other == current { return Result(value: current) }
    guard let base, let current, let other,
      !base.contains(0), !current.contains(0), !other.contains(0),
      let baseText = String(data: base, encoding: .utf8),
      let currentText = String(data: current, encoding: .utf8),
      let otherText = String(data: other, encoding: .utf8)
    else { return nil }
    let original = baseText.components(separatedBy: "\n")
    let left = currentText.components(separatedBy: "\n")
    let right = otherText.components(separatedBy: "\n")
    guard original.count <= 4_000, left.count <= 4_000, right.count <= 4_000,
      original.count * max(left.count, right.count) <= 4_000_000,
      let leftEdits = edits(from: original, to: left),
      let rightEdits = edits(from: original, to: right)
    else { return nil }

    var combined = leftEdits
    for edit in rightEdits {
      if combined.contains(edit) { continue }
      guard !combined.contains(where: { overlaps($0, edit) }) else { return nil }
      combined.append(edit)
    }
    var lines = original
    for edit in combined.sorted(by: { $0.start > $1.start }) {
      lines.replaceSubrange(edit.start..<edit.end, with: edit.lines)
    }
    return Result(value: Data(lines.joined(separator: "\n").utf8))
  }

  private static func edits(from original: [String], to updated: [String]) -> [Edit]? {
    let difference = updated.difference(from: original)
    var removals = Set<Int>()
    var insertions = Set<Int>()
    for change in difference {
      switch change {
      case .remove(let offset, _, _): removals.insert(offset)
      case .insert(let offset, _, _): insertions.insert(offset)
      }
    }
    var result: [Edit] = []
    var i = 0
    var j = 0
    var start: Int?
    var replacement: [String] = []
    while i < original.count || j < updated.count {
      if i < original.count, removals.contains(i) {
        if start == nil { start = i }
        i += 1
      } else if j < updated.count, insertions.contains(j) {
        if start == nil { start = i }
        replacement.append(updated[j])
        j += 1
      } else {
        guard i < original.count, j < updated.count, original[i] == updated[j] else { return nil }
        if let start { result.append(Edit(start: start, end: i, lines: replacement)) }
        start = nil
        replacement = []
        i += 1
        j += 1
      }
    }
    if let start { result.append(Edit(start: start, end: i, lines: replacement)) }
    return result
  }

  private static func overlaps(_ a: Edit, _ b: Edit) -> Bool {
    if a.start == a.end, b.start == b.end { return a.start == b.start }
    if a.start == a.end { return a.start >= b.start && a.start <= b.end }
    if b.start == b.end { return b.start >= a.start && b.start <= a.end }
    return max(a.start, b.start) < min(a.end, b.end)
  }
}
