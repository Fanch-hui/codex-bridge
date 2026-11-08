import BridgeSecurity
import Foundation

extension AgentWorkspaceStore {
  func privateGitFingerprint(root: RegisteredRoot) throws -> String {
    let base = URL(fileURLWithPath: root.canonicalPath, isDirectory: true)
    let resolver = ProjectPathResolver(root: root)
    let reader = SecureProjectFileWriter(maximumBytes: 10 * 1_024 * 1_024)
    var pending = [""]
    var entries: [String] = []
    var totalBytes = 0
    while let directory = pending.popLast() {
      try Task.checkCancellation()
      let location = directory.isEmpty ? base : base.appendingPathComponent(directory)
      for name in try FileManager.default.contentsOfDirectory(atPath: location.path).sorted() {
        let value = directory.isEmpty ? name : "\(directory)/\(name)"
        guard value.utf8.count <= 4_096, entries.count < AgentWorkspaceInventory.maximumEntries
        else {
          throw AgentWorkspaceError.resourceLimit
        }
        let path = try SecureRelativePath(value)
        let metadata = try FileSystemEntryMetadata(at: base.appendingPathComponent(value))
        guard !metadata.isSymbolicLink else { throw AgentWorkspaceError.unsupportedEntry(value) }
        let mode = try AgentWorkspaceInventory.mode(at: root, path: value)
        if metadata.isDirectory {
          guard path.components.count <= 64 else { throw AgentWorkspaceError.resourceLimit }
          entries.append("d\(value.utf8.count):\(value):\(mode)")
          pending.append(value)
        } else if metadata.isRegularFile {
          guard let data = try reader.readContent(relativePath: path, through: resolver),
            totalBytes <= 512 * 1_024 * 1_024 - data.count
          else { throw AgentWorkspaceError.resourceLimit }
          totalBytes += data.count
          entries.append(
            "f\(value.utf8.count):\(value):\(mode):\(SecureFileRevision.digest(of: data).sha256)")
        } else {
          throw AgentWorkspaceError.unsupportedEntry(value)
        }
      }
    }
    return SecureFileRevision.digest(of: Data(entries.sorted().joined(separator: "\n").utf8)).sha256
  }
}
