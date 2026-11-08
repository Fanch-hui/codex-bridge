import BridgeAgentCore
import BridgeGit
import BridgeProjects
import BridgeSecurity
import Foundation

public actor AgentWorkspaceStore {
  let directory: URL
  let writer = SecureProjectFileWriter(maximumBytes: AgentWorkspaceInventory.maximumFileBytes)
  let directoryMutation = SecureProjectDirectoryMutation(
    maximumBytes: AgentWorkspaceInventory.maximumFileBytes)
  var activeIDs: Set<String> = []
  var managementRoot: RegisteredRoot?

  public init(directory: URL) {
    self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
  }

  public func prepare(
    id: String,
    projectRoot: RegisteredRoot,
    forbiddenPatterns: [ForbiddenPathPattern] = []
  ) async throws -> AgentWorkspaceSnapshot {
    try validateIdentifier(id)
    guard activeIDs.insert(id).inserted else { throw AgentWorkspaceError.workspaceBusy }
    defer { activeIDs.remove(id) }
    try projectRoot.validateCurrentIdentity()
    let root = try ensureManagementRoot()
    guard !AgentPathSemantics.isContained(root.canonicalPath, in: projectRoot.canonicalPath),
      !AgentPathSemantics.isContained(projectRoot.canonicalPath, in: root.canonicalPath)
    else { throw AgentWorkspaceError.invalidStorage }
    if let existing = try snapshot(id: id) {
      guard existing.projectRoot == projectRoot else { throw AgentWorkspaceError.projectMismatch }
      let manifest = try readManifest(id: id)
      guard manifest.forbiddenPatterns == forbiddenPatterns else {
        throw AgentWorkspaceError.projectMismatch
      }
      return existing
    }
    try ensureWorkspaceCapacity()

    let temporary = directory.appendingPathComponent("\(id).preparing.\(UUID().uuidString)")
    let target = workspaceDirectory(id)
    try FileManager.default.createDirectory(
      at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do {
      let baselineURL = temporary.appendingPathComponent("baseline", isDirectory: true)
      let workspaceURL = temporary.appendingPathComponent("workspace", isDirectory: true)
      let runtimeURL = temporary.appendingPathComponent("runtime", isDirectory: true)
      try FileManager.default.createDirectory(at: baselineURL, withIntermediateDirectories: false)
      try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: false)
      try FileManager.default.createDirectory(
        at: runtimeURL, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      let baseline = try RegisteredRoot(capturing: baselineURL)
      let workspace = try RegisteredRoot(capturing: workspaceURL)
      let runtime = try RegisteredRoot(capturing: runtimeURL)
      let modes = try copySnapshot(
        projectRoot: projectRoot, baseline: baseline, workspace: workspace,
        forbiddenPatterns: forbiddenPatterns)
      let sourceGit = URL(fileURLWithPath: projectRoot.canonicalPath, isDirectory: true)
        .appendingPathComponent(".git")
      let hasGit = FileManager.default.fileExists(atPath: sourceGit.path)
      if hasGit {
        try await initializePrivateGit(at: workspaceURL, staging: temporary)
      }
      var manifest = AgentWorkspaceManifest(
        version: 1, id: id, projectRoot: projectRoot, baselineIdentity: baseline.identity,
        workspaceIdentity: workspace.identity, runtimeIdentity: runtime.identity,
        forbiddenPatterns: forbiddenPatterns, modes: modes, revision: 0)
      manifest.activated = false
      manifest.privateGit = hasGit
      if hasGit {
        let git = try RegisteredRoot(capturing: workspaceURL.appendingPathComponent(".git"))
        manifest.privateGitIdentity = git.identity
        manifest.privateGitFingerprint = try privateGitFingerprint(root: git)
      }
      try writeJSON(manifest, to: temporary.appendingPathComponent("manifest.json"))
      try root.validateCurrentIdentity()
      try FileManager.default.moveItem(at: temporary, to: target)
      guard let result = try snapshot(id: id) else { throw AgentWorkspaceError.invalidStorage }
      return result
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }

  public func snapshot(id: String) throws -> AgentWorkspaceSnapshot? {
    try validateIdentifier(id)
    let folder = workspaceDirectory(id)
    guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
    _ = try ensureManagementRoot()
    let folderMetadata = try FileSystemEntryMetadata(at: folder)
    guard folderMetadata.isDirectory, !folderMetadata.isSymbolicLink else {
      throw AgentWorkspaceError.invalidStorage
    }
    let manifest = try readManifest(id: id)
    guard manifest.version == 1, manifest.id == id else { throw AgentWorkspaceError.invalidStorage }
    try manifest.projectRoot.validateCurrentIdentity()
    let workspace = try privateRoot(
      at: folder.appendingPathComponent("workspace", isDirectory: true),
      identity: manifest.workspaceIdentity)
    let runtime = try privateRoot(
      at: folder.appendingPathComponent("runtime", isDirectory: true),
      identity: manifest.runtimeIdentity)
    return AgentWorkspaceSnapshot(
      id: id, projectRoot: manifest.projectRoot, workspaceRoot: workspace,
      runtimeRoot: runtime, revision: manifest.revision)
  }

  func workspaceDirectory(_ id: String) -> URL {
    directory.appendingPathComponent(id, isDirectory: true)
  }

  func readManifest(id: String) throws -> AgentWorkspaceManifest {
    try readJSON(AgentWorkspaceManifest.self, id: id, name: "manifest.json")
  }

  func readJSON<T: Decodable>(_ type: T.Type, id: String, name: String) throws -> T {
    let root = try ensureManagementRoot()
    let path = try SecureRelativePath("\(id)/\(name)")
    let reader = SecureProjectFileWriter(maximumBytes: 128 * 1_024 * 1_024)
    guard
      let data = try reader.readContent(
        relativePath: path, through: ProjectPathResolver(root: root))
    else { throw AgentWorkspaceError.invalidStorage }
    return try JSONDecoder().decode(type, from: data)
  }

  func writeManifest(_ manifest: AgentWorkspaceManifest) throws {
    try writeJSON(
      manifest, to: workspaceDirectory(manifest.id).appendingPathComponent("manifest.json"))
  }

  func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.synchronize()
  }

  func validateIdentifier(_ id: String) throws {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    guard !id.isEmpty, id.utf8.count <= 128, id != ".", id != "..",
      id.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) })
    else { throw AgentWorkspaceError.invalidIdentifier }
  }

  func ensureManagementRoot() throws -> RegisteredRoot {
    guard directory.isFileURL, AgentPathSemantics.isAbsolute(directory.path) else {
      throw AgentWorkspaceError.invalidStorage
    }
    if let managementRoot {
      try managementRoot.validateCurrentIdentity()
      return managementRoot
    }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let metadata = try FileSystemEntryMetadata(at: directory)
    guard metadata.isDirectory, !metadata.isSymbolicLink else {
      throw AgentWorkspaceError.invalidStorage
    }
    let root = try RegisteredRoot(capturing: directory)
    guard AgentPathSemantics.isContained(root.canonicalPath, in: directory.path),
      AgentPathSemantics.isContained(directory.path, in: root.canonicalPath)
    else { throw AgentWorkspaceError.invalidStorage }
    managementRoot = root
    return root
  }

  func privateRoot(at url: URL, identity: FileSystemIdentity) throws -> RegisteredRoot {
    let metadata = try FileSystemEntryMetadata(at: url)
    guard metadata.isDirectory, !metadata.isSymbolicLink else {
      throw AgentWorkspaceError.invalidStorage
    }
    let root = try RegisteredRoot(capturing: url)
    guard root.identity == identity else { throw AgentWorkspaceError.invalidStorage }
    return root
  }

  private func copySnapshot(
    projectRoot: RegisteredRoot, baseline: RegisteredRoot, workspace: RegisteredRoot,
    forbiddenPatterns: [ForbiddenPathPattern]
  ) throws -> [String: Int] {
    let policy = ProjectFilePolicy(forbiddenPatterns: forbiddenPatterns)
    let inventory = AgentWorkspaceInventory(root: projectRoot, policy: policy)
    let paths = try inventory.paths()
    let project = ProjectPathResolver(root: projectRoot)
    let baselineResolver = ProjectPathResolver(root: baseline)
    let workspaceResolver = ProjectPathResolver(root: workspace)
    var modes: [String: Int] = [:]
    var revisions: [String: SecureFileRevision] = [:]
    for value in paths {
      try Task.checkCancellation()
      let path = try SecureRelativePath(value)
      guard let data = try writer.readContent(relativePath: path, through: project) else {
        throw AgentWorkspaceError.revisionConflict(value)
      }
      try AgentWorkspaceInventory.validateContent(data, path: value)
      let mode = try AgentWorkspaceInventory.mode(at: projectRoot, path: value)
      _ = try writer.write(
        relativePath: path, through: baselineResolver, mode: .create, content: data,
        expectedSHA256: nil, createParents: true, allowsBinaryContent: true)
      _ = try writer.write(
        relativePath: path, through: workspaceResolver, mode: .create, content: data,
        expectedSHA256: nil, createParents: true, allowsBinaryContent: true)
      try AgentWorkspaceInventory.setMode(mode, at: workspace, path: value)
      modes[value] = mode
      revisions[value] = .digest(of: data)
    }
    guard try inventory.paths() == paths else { throw AgentWorkspaceError.revisionConflict("") }
    for value in paths {
      let path = try SecureRelativePath(value)
      guard try writer.revision(relativePath: path, through: project) == revisions[value],
        try AgentWorkspaceInventory.mode(at: projectRoot, path: value) == modes[value]
      else { throw AgentWorkspaceError.revisionConflict(value) }
    }
    return modes
  }
}
