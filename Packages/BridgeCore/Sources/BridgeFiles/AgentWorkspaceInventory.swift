import BridgeSecurity
import Foundation

struct AgentWorkspaceInventory {
  static let maximumFileBytes = 8 * 1_024 * 1_024
  static let maximumTotalBytes = 256 * 1_024 * 1_024
  static let maximumFiles = 20_000
  static let maximumEntries = 100_000
  static let ignoredDirectories: Set<String> = [
    ".git", ".build", ".cache", ".gradle", ".next", ".swiftpm", ".turbo",
    ".venv", "__pycache__", "build", "coverage", "deriveddata", "dist", "node_modules",
  ]
  static let privateBasenames: Set<String> = [
    ".netrc", ".npmrc", ".pypirc", "credentials.json", "service-account.json",
  ]

  let root: RegisteredRoot
  let policy: ProjectFilePolicy

  func paths() throws -> [String] {
    try root.validateCurrentIdentity()
    let base = URL(fileURLWithPath: root.canonicalPath, isDirectory: true)
    let resolver = ProjectPathResolver(root: root)
    var pending = [""]
    var paths: [String] = []
    var entries = 0
    var totalBytes = 0
    var pathBytes = 0

    while let directory = pending.popLast() {
      try Task.checkCancellation()
      let url = directory.isEmpty ? base : base.appendingPathComponent(directory, isDirectory: true)
      let before: ResolvedProjectPath?
      if directory.isEmpty {
        before = nil
      } else {
        before = try resolver.resolve(SecureRelativePath(directory))
      }
      let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
      if let before {
        let after = try resolver.resolve(SecureRelativePath(directory))
        guard before.identity == after.identity else { throw AgentWorkspaceError.invalidStorage }
      }
      for name in names {
        entries += 1
        guard entries <= Self.maximumEntries else { throw AgentWorkspaceError.resourceLimit }
        if name.lowercased() == ".git" || Self.privateBasenames.contains(name.lowercased()) {
          continue
        }
        let relative = directory.isEmpty ? name : "\(directory)/\(name)"
        guard relative.utf8.count <= 4_096 else { throw AgentWorkspaceError.resourceLimit }
        let path = try SecureRelativePath(relative)
        guard policy.allows(path) else { continue }
        let child = base.appendingPathComponent(relative)
        let metadata = try FileSystemEntryMetadata(at: child)
        if metadata.isSymbolicLink { throw AgentWorkspaceError.unsupportedEntry(relative) }
        if metadata.isDirectory {
          if !Self.ignoredDirectories.contains(name.lowercased()) {
            guard path.components.count <= 64 else { throw AgentWorkspaceError.resourceLimit }
            pending.append(relative)
          }
        } else if metadata.isRegularFile {
          guard let size = metadata.fileSize, size >= 0, size <= Self.maximumFileBytes,
            totalBytes <= Self.maximumTotalBytes - size
          else { throw AgentWorkspaceError.resourceLimit }
          totalBytes += size
          guard pathBytes <= 8 * 1_024 * 1_024 - relative.utf8.count else {
            throw AgentWorkspaceError.resourceLimit
          }
          pathBytes += relative.utf8.count
          paths.append(relative)
          guard paths.count <= Self.maximumFiles else { throw AgentWorkspaceError.resourceLimit }
        } else {
          throw AgentWorkspaceError.unsupportedEntry(relative)
        }
      }
    }
    try root.validateCurrentIdentity()
    return paths.sorted()
  }

  static func mode(at root: RegisteredRoot, path: String) throws -> Int {
    #if os(Windows)
      return 0
    #else
      let url = URL(fileURLWithPath: root.canonicalPath, isDirectory: true)
        .appendingPathComponent(path)
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard let mode = attributes[.posixPermissions] as? NSNumber else {
        throw AgentWorkspaceError.unsupportedEntry(path)
      }
      return mode.intValue & 0o777
    #endif
  }

  static func validateContent(_ data: Data?, path: String) throws {
    guard let data, let text = String(data: data, encoding: .utf8) else { return }
    if ProjectSecretRedactor.containsSensitiveContent(text) {
      throw AgentWorkspaceError.unsupportedEntry(path)
    }
  }

  static func setMode(_ mode: Int, at root: RegisteredRoot, path: String) throws {
    #if !os(Windows)
      let url = URL(fileURLWithPath: root.canonicalPath, isDirectory: true)
        .appendingPathComponent(path)
      try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    #endif
  }
}
