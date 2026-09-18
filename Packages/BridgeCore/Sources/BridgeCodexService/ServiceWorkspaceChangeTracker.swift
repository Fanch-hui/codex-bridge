import BridgeAgentCore
import Foundation

/// Captures bounded file metadata so provider runs can report writes even when
/// the provider only exposes a shell command instead of file-change events.
struct ServiceWorkspaceChangeTracker: Sendable {
  private struct FileStamp: Equatable, Sendable {
    let byteCount: UInt64
    let modificationTime: TimeInterval
  }

  private static let maximumFiles = 20_000
  private let root: String
  private let baseline: [String: FileStamp]

  init?(projectRoot: String) {
    guard let baseline = Self.snapshot(root: projectRoot) else { return nil }
    root = projectRoot
    self.baseline = baseline
  }

  func changedFiles() -> [String] {
    guard let current = Self.snapshot(root: root) else { return [] }
    let paths = Set(baseline.keys).union(current.keys)
    return paths.filter { baseline[$0] != current[$0] }.sorted()
  }

  private static func snapshot(root: String) -> [String: FileStamp]? {
    let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      let enumerator = FileManager.default.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [
          .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
          .contentModificationDateKey,
        ],
        options: []
      )
    else {
      return nil
    }

    var result: [String: FileStamp] = [:]
    for case let fileURL as URL in enumerator {
      guard let relative = relativePath(fileURL, root: rootURL) else { continue }
      if shouldSkip(relative) {
        enumerator.skipDescendants()
        continue
      }
      guard
        let values = try? fileURL.resourceValues(forKeys: [
          .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
          .contentModificationDateKey,
        ])
      else {
        continue
      }
      guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
      guard result.count < maximumFiles else { return nil }
      let byteCount = UInt64(max(0, values.fileSize ?? 0))
      let modificationTime = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
      result[relative] = FileStamp(
        byteCount: byteCount,
        modificationTime: modificationTime
      )
    }
    return result
  }

  private static func relativePath(_ fileURL: URL, root: URL) -> String? {
    let path = fileURL.standardizedFileURL.path
    let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard path.hasPrefix(rootPath) else { return nil }
    let value = String(path.dropFirst(rootPath.count)).replacingOccurrences(of: "\\", with: "/")
    guard AgentPathSemantics.relativeComponents(value) != nil else { return nil }
    return value
  }

  private static func shouldSkip(_ path: String) -> Bool {
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    let ignored: Set<Substring> = [".git", ".codex", "node_modules", ".build", ".venv"]
    if components.contains(where: ignored.contains) { return true }
    let filename = components.last.map(String.init) ?? ""
    return filename == "service.sqlite"
      || filename == "service.sqlite-shm"
      || filename == "service.sqlite-wal"
  }
}
