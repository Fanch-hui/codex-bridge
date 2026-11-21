import BridgeAgentCore
import BridgeSecurity
import Crypto
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif os(Windows)
  import WinSDK
#endif

enum SkillHubHashing {
  static let maximumHashedFiles = 512
  static let maximumHashedTotalBytes = 10 * 1_024 * 1_024
  static let ignoredEntries: Set<String> = [
    ".ds_store", "thumbs.db", ".git", "__pycache__", "node_modules", ".venv",
  ]
  private static let forbiddenTargetComponents: Set<String> = [
    ".ssh", ".aws", ".gnupg", "keychains", "cookies", "secrets", ".kube",
  ]

  static func isSafeResolvedTarget(_ url: URL) -> Bool {
    let lowerComponents = url.standardizedFileURL.pathComponents.map { $0.lowercased() }
    return !lowerComponents.contains(where: forbiddenTargetComponents.contains)
  }

  static func normalizedDocumentHash(_ text: String) -> String {
    let normalized =
      text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return sha256Hex(Data(normalized.utf8))
  }

  static func bundleSnapshot(
    directory: URL,
    documentHash: String,
    fileManager: FileManager
  ) -> (bundleHash: String, resourceFiles: [String], hasReferences: Bool) {
    let resolvedRoot = directory.resolvingSymlinksInPath().standardizedFileURL
    var files: [String] = []
    var totalBytes = 0
    collectFiles(
      in: resolvedRoot,
      root: resolvedRoot,
      depth: 0,
      fileManager: fileManager,
      files: &files,
      totalBytes: &totalBytes
    )
    files.sort()

    var hasher = SHA256()
    hasher.update(data: Data("doc:\(documentHash)\n".utf8))
    var hasReferences = false
    for relativePath in files {
      if relativePath.hasPrefix("references/") { hasReferences = true }
      if relativePath == "SKILL.md" { continue }
      let fileURL = resolvedRoot.appendingPathComponent(relativePath)
      guard let data = try? Data(contentsOf: fileURL) else { continue }
      let digest = sha256Hex(data)
      hasher.update(data: Data("\(relativePath):\(digest)\n".utf8))
    }
    let bundleHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    return (bundleHash, files, hasReferences)
  }

  static func physicalIdentityKey(for url: URL, isDirectory: Bool) -> String {
    let canonical = url.resolvingSymlinksInPath().standardizedFileURL
    if isDirectory, let root = try? RegisteredRoot(capturing: canonical) {
      return "id:\(root.identity.device):\(root.identity.inode)"
    }
    #if os(Windows)
      let handle = canonical.path.withCString(encodedAs: UTF16.self) { wide in
        CreateFileW(
          wide,
          DWORD(0),
          DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE),
          nil,
          DWORD(OPEN_EXISTING),
          DWORD(isDirectory ? FILE_FLAG_BACKUP_SEMANTICS : 0),
          nil
        )
      }
      if handle != INVALID_HANDLE_VALUE {
        defer { _ = CloseHandle(handle) }
        var info = BY_HANDLE_FILE_INFORMATION()
        if GetFileInformationByHandle(handle, &info) {
          let index = (UInt64(info.nFileIndexHigh) << 32) | UInt64(info.nFileIndexLow)
          return "id:\(info.dwVolumeSerialNumber):\(index)"
        }
      }
      return "path:\(canonical.path.lowercased())"
    #else
      var metadata = stat()
      if canonical.path.withCString({ stat($0, &metadata) }) == 0 {
        return "id:\(metadata.st_dev):\(metadata.st_ino)"
      }
      return "path:\(canonical.path)"
    #endif
  }

  static func modifiedTimestamp(at url: URL, fileManager: FileManager) -> String? {
    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
      let date = attributes[.modificationDate] as? Date
    else { return nil }
    return date.formatted(.iso8601)
  }

  static func occurrenceID(sourceID: String, entryPath: String) -> String {
    let hex = sha256Hex(Data("\(sourceID)|\(entryPath)".utf8))
    return String(hex.prefix(24))
  }

  static func stripFrontmatter(from text: String) -> String {
    let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---",
      let endIndex = lines.dropFirst().firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces) == "---"
      })
    else {
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let remainder = lines[(endIndex + 1)...].map(String.init).joined(separator: "\n")
    return remainder.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func fallbackDescription(fromBody body: String, sourceName: String) -> String {
    for rawLine in body.split(whereSeparator: \.isNewline) {
      let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("```") { continue }
      let plain = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "-*> "))
      if !plain.isEmpty { return String(plain.prefix(240)) }
    }
    return "来自 \(sourceName) 的技能"
  }

  static func rootFingerprint(for roots: [String], fileManager: FileManager) -> String {
    var hasher = SHA256()
    for rootPath in roots.sorted() {
      let url = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
      guard fileManager.fileExists(atPath: url.path) else {
        hasher.update(data: Data("missing:\(rootPath)\n".utf8))
        continue
      }
      let rootMtime = modifiedEpoch(at: url, fileManager: fileManager)
      hasher.update(data: Data("root:\(rootPath):\(rootMtime)\n".utf8))
      guard
        let entries = try? fileManager.contentsOfDirectory(
          at: url, includingPropertiesForKeys: nil, options: []
        )
      else { continue }
      for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let name = entry.lastPathComponent
        let childMtime = modifiedEpoch(at: entry, fileManager: fileManager)
        let manifestMtime = modifiedEpoch(
          at: entry.appendingPathComponent("SKILL.md"), fileManager: fileManager)
        hasher.update(data: Data("entry:\(name):\(childMtime):\(manifestMtime)\n".utf8))
      }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func modifiedEpoch(at url: URL, fileManager: FileManager) -> Int64 {
    guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
      let date = attributes[.modificationDate] as? Date
    else { return 0 }
    return Int64((date.timeIntervalSince1970 * 1_000).rounded())
  }

  private static func collectFiles(
    in directory: URL,
    root: URL,
    depth: Int,
    fileManager: FileManager,
    files: inout [String],
    totalBytes: inout Int
  ) {
    guard depth <= 6, files.count < maximumHashedFiles else { return }
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil, options: []
      )
    else { return }
    for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      guard files.count < maximumHashedFiles else { return }
      let name = entry.lastPathComponent
      let lower = name.lowercased()
      if ignoredEntries.contains(lower) || lower.hasSuffix(".pyc") { continue }
      guard let metadata = try? FileSystemEntryMetadata(at: entry), !metadata.isSymbolicLink else {
        continue
      }
      if metadata.isDirectory {
        collectFiles(
          in: entry,
          root: root,
          depth: depth + 1,
          fileManager: fileManager,
          files: &files,
          totalBytes: &totalBytes
        )
      } else if metadata.isRegularFile {
        let size = metadata.fileSize ?? 0
        guard totalBytes + size <= maximumHashedTotalBytes else { continue }
        let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
        guard let relative = AgentPathSemantics.relativePath(resolved.path, from: root.path),
          !relative.isEmpty
        else { continue }
        totalBytes += size
        files.append(relative.replacingOccurrences(of: "\\", with: "/"))
      }
    }
  }
}
