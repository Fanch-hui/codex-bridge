import BridgeSecurity
import Foundation

struct AgentWorkspaceExcludedEntries: Equatable, Sendable {
  let paths: [String]
  let omitted: Int

  var isEmpty: Bool { paths.isEmpty && omitted == 0 }
}

extension AgentWorkspaceInventory {
  static let maximumReportedExcludedPaths = 256

  /// Lists what `paths()` skips on purpose: excluded directories at any depth, private files and
  /// policy-forbidden paths. Only names are inspected, so secret files are never opened and an
  /// excluded directory is reported as one `dir/` entry instead of being walked.
  func excludedEntries(limit: Int) throws -> AgentWorkspaceExcludedEntries {
    try root.validateCurrentIdentity()
    let base = URL(fileURLWithPath: root.canonicalPath, isDirectory: true)
    var pending = [""]
    var reported: [String] = []
    var total = 0
    var entries = 0
    while let directory = pending.popLast() {
      try Task.checkCancellation()
      let url = directory.isEmpty ? base : base.appendingPathComponent(directory, isDirectory: true)
      for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
        entries += 1
        guard entries <= Self.maximumEntries else { throw AgentWorkspaceError.resourceLimit }
        let lowered = name.lowercased()
        // The workspace root `.git` is Bridge's private Git metadata, not agent output.
        if directory.isEmpty, lowered == ".git" { continue }
        let relative = directory.isEmpty ? name : "\(directory)/\(name)"
        guard relative.utf8.count <= 4_096 else { throw AgentWorkspaceError.resourceLimit }
        let metadata = try FileSystemEntryMetadata(at: base.appendingPathComponent(relative))
        let isRealDirectory = metadata.isDirectory && !metadata.isSymbolicLink
        let path = try SecureRelativePath(relative)
        let excluded =
          lowered == ".git" || Self.privateBasenames.contains(lowered) || !policy.allows(path)
          || (isRealDirectory && Self.ignoredDirectories.contains(lowered))
        if excluded {
          total += 1
          if reported.count < limit { reported.append(isRealDirectory ? relative + "/" : relative) }
        } else if isRealDirectory, path.components.count <= 64 {
          pending.append(relative)
        }
      }
    }
    try root.validateCurrentIdentity()
    return AgentWorkspaceExcludedEntries(
      paths: reported.sorted(), omitted: total - reported.count)
  }
}
