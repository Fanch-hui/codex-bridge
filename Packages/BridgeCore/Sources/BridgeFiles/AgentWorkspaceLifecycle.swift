import BridgeSecurity
import Foundation

extension AgentWorkspaceStore {
  static let maximumManagedWorkspaces = 64

  func ensureWorkspaceCapacity() throws {
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    var count = 0
    for name in names {
      let url = directory.appendingPathComponent(name)
      let metadata = try FileSystemEntryMetadata(at: url)
      if metadata.isDirectory || metadata.isSymbolicLink { count += 1 }
      guard count < Self.maximumManagedWorkspaces else { throw AgentWorkspaceError.resourceLimit }
    }
  }

  /// Persist before starting a process that can use the workspace or its runtime directory.
  public func markStarted(id: String) throws {
    try validateIdentifier(id)
    guard activeIDs.insert(id).inserted else { throw AgentWorkspaceError.workspaceBusy }
    defer { activeIDs.remove(id) }
    guard try snapshot(id: id) != nil else { throw AgentWorkspaceError.workspaceUnavailable }
    var manifest = try readManifest(id: id)
    if manifest.activated == true { return }
    guard manifest.activated == false, manifest.revision == 0, manifest.privateGit != nil,
      manifest.pendingConflicts?.isEmpty ?? true,
      !FileManager.default.fileExists(atPath: journalURL(id).path),
      !FileManager.default.fileExists(atPath: resolutionJournalURL(id).path)
    else { throw AgentWorkspaceError.invalidStorage }
    manifest.activated = true
    try writeManifest(manifest)
  }

  /// Remove only an untouched preparation that has never been activated.
  @discardableResult
  public func discardPrepared(id: String) throws -> Bool {
    try validateIdentifier(id)
    guard activeIDs.insert(id).inserted else { throw AgentWorkspaceError.workspaceBusy }
    defer { activeIDs.remove(id) }
    guard let snapshot = try snapshot(id: id) else { return false }
    let manifest = try readManifest(id: id)
    guard manifest.activated == false, manifest.revision == 0, manifest.privateGit != nil,
      manifest.pendingConflicts?.isEmpty ?? true,
      !FileManager.default.fileExists(atPath: journalURL(id).path),
      !FileManager.default.fileExists(atPath: resolutionJournalURL(id).path),
      !FileManager.default.fileExists(
        atPath: workspaceDirectory(id).appendingPathComponent("conflicts").path),
      try FileManager.default.contentsOfDirectory(atPath: snapshot.runtimeRoot.canonicalPath)
        .isEmpty
    else { return false }
    guard try hasOnlyPreparedStorage(id: id, privateGit: manifest.privateGit == true) else {
      return false
    }
    if manifest.privateGit == true {
      guard let identity = manifest.privateGitIdentity,
        let expected = manifest.privateGitFingerprint
      else { return false }
      do {
        let git = try privateRoot(
          at: URL(fileURLWithPath: snapshot.workspaceRoot.canonicalPath, isDirectory: true)
            .appendingPathComponent(".git", isDirectory: true), identity: identity)
        guard try privateGitFingerprint(root: git) == expected else { return false }
      } catch AgentWorkspaceError.unsupportedEntry(_) {
        return false
      } catch AgentWorkspaceError.resourceLimit {
        return false
      }
    }
    let baseline = try baselineRoot(manifest)
    let policy = ProjectFilePolicy(forbiddenPatterns: manifest.forbiddenPatterns)
    let paths: [String]
    do {
      paths = try AgentWorkspaceInventory(root: baseline, policy: policy).paths()
    } catch AgentWorkspaceError.unsupportedEntry(_) {
      return false
    } catch AgentWorkspaceError.resourceLimit {
      return false
    }
    let workspacePaths: [String]
    do {
      workspacePaths = try AgentWorkspaceInventory(root: snapshot.workspaceRoot, policy: policy)
        .paths()
    } catch AgentWorkspaceError.unsupportedEntry(_) {
      return false
    } catch AgentWorkspaceError.resourceLimit {
      return false
    }
    guard paths == workspacePaths,
      try containsOnlyPreparedEntries(
        paths: paths, baseline: baseline, workspace: baseline, privateGit: false),
      try containsOnlyPreparedEntries(
        paths: paths, baseline: baseline, workspace: snapshot.workspaceRoot,
        privateGit: manifest.privateGit == true)
    else { return false }
    let original = ProjectPathResolver(root: baseline)
    let workspace = ProjectPathResolver(root: snapshot.workspaceRoot)
    for value in paths {
      let path = try SecureRelativePath(value)
      guard
        try writer.readContent(relativePath: path, through: original)
          == writer.readContent(relativePath: path, through: workspace),
        try AgentWorkspaceInventory.mode(at: snapshot.workspaceRoot, path: value)
          == manifest.modes[value]
      else { return false }
    }
    guard
      try FileManager.default.contentsOfDirectory(atPath: snapshot.runtimeRoot.canonicalPath)
        .isEmpty,
      try self.snapshot(id: id) == snapshot
    else { return false }
    try FileManager.default.removeItem(at: workspaceDirectory(id))
    return true
  }

  private func hasOnlyPreparedStorage(id: String, privateGit: Bool) throws -> Bool {
    let folder = workspaceDirectory(id)
    var expected: Set<String> = ["baseline", "workspace", "runtime", "manifest.json"]
    if privateGit { expected.insert("git-template") }
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    guard Set(names) == expected else { return false }
    if privateGit {
      let template = folder.appendingPathComponent("git-template", isDirectory: true)
      let metadata = try FileSystemEntryMetadata(at: template)
      guard metadata.isDirectory, !metadata.isSymbolicLink,
        try FileManager.default.contentsOfDirectory(atPath: template.path).isEmpty
      else { return false }
    }
    return true
  }

  private func containsOnlyPreparedEntries(
    paths: [String], baseline: RegisteredRoot, workspace: RegisteredRoot, privateGit: Bool
  ) throws -> Bool {
    var allowedFiles = Set(paths)
    var allowedDirectories = Set<String>()
    for value in paths {
      let parts = value.split(separator: "/").map(String.init)
      for end in 1..<parts.count {
        allowedDirectories.insert(parts.prefix(end).joined(separator: "/"))
      }
    }
    let root = URL(fileURLWithPath: workspace.canonicalPath, isDirectory: true)
    var pending = [""]
    var sawGit = !privateGit
    while let relativeDirectory = pending.popLast() {
      let url = relativeDirectory.isEmpty ? root : root.appendingPathComponent(relativeDirectory)
      for name in try FileManager.default.contentsOfDirectory(atPath: url.path) {
        let value = relativeDirectory.isEmpty ? name : "\(relativeDirectory)/\(name)"
        let child = root.appendingPathComponent(value)
        let metadata = try FileSystemEntryMetadata(at: child)
        guard !metadata.isSymbolicLink else { return false }
        if value == ".git", privateGit, metadata.isDirectory {
          sawGit = true
          continue
        }
        if metadata.isDirectory {
          guard allowedDirectories.contains(value),
            try AgentWorkspaceInventory.mode(at: baseline, path: value)
              == AgentWorkspaceInventory.mode(at: workspace, path: value)
          else { return false }
          pending.append(value)
        } else if metadata.isRegularFile {
          guard allowedFiles.remove(value) != nil else { return false }
        } else {
          return false
        }
      }
    }
    return allowedFiles.isEmpty && sawGit
  }
}
