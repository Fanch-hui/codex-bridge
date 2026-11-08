import BridgeSecurity
import Foundation

public struct AgentWorkspaceMergeCandidate: Sendable {
  public let id: String
  public let workspaceID: String
  public let root: RegisteredRoot
  let revision: Int
  let changes: [AgentWorkspaceChange]
  let projectFiles: [String: AgentWorkspaceFileFingerprint]
  let baselineFiles: [String: AgentWorkspaceFileFingerprint]
  let workspaceFiles: [String: AgentWorkspaceFileFingerprint]
  let candidateFiles: [String: AgentWorkspaceFileFingerprint]
}

struct AgentWorkspaceFileFingerprint: Equatable, Sendable {
  let sha256: String
  let mode: Int
}

private struct AgentWorkspaceCandidateIdentity: Codable {
  let id: String
  let workspaceID: String
  let root: RegisteredRoot
}

extension AgentWorkspaceStore {
  /// Capture the current project and overlay the planned result for isolated validation.
  public func prepareMergeCandidate(
    plan: AgentWorkspaceMergePlan, candidateID: String? = nil
  ) throws
    -> AgentWorkspaceMergeCandidate
  {
    try validateIdentifier(plan.id)
    guard activeIDs.insert(plan.id).inserted else { throw AgentWorkspaceError.workspaceBusy }
    defer { activeIDs.remove(plan.id) }
    guard plan.conflicts.isEmpty else { throw AgentWorkspaceError.mergeConflict(plan.conflicts) }
    guard let snapshot = try snapshot(id: plan.id) else {
      throw AgentWorkspaceError.workspaceUnavailable
    }
    guard snapshot.revision == plan.revision,
      !FileManager.default.fileExists(atPath: journalURL(plan.id).path),
      !FileManager.default.fileExists(atPath: resolutionJournalURL(plan.id).path),
      !FileManager.default.fileExists(atPath: synchronizationJournalURL(plan.id).path),
      !FileManager.default.fileExists(atPath: conflictRepairJournalURL(plan.id).path)
    else { throw AgentWorkspaceError.revisionConflict("") }
    let manifest = try readManifest(id: plan.id)
    guard manifest.pendingConflicts?.isEmpty ?? true else {
      throw AgentWorkspaceError.mergeConflict(manifest.pendingConflicts?.keys.sorted() ?? [])
    }
    let policy = ProjectFilePolicy(forbiddenPatterns: manifest.forbiddenPatterns)
    let baseline = try baselineRoot(manifest)
    let projectFiles = try fingerprint(root: snapshot.projectRoot, policy: policy)
    let baselineFiles = try fingerprint(root: baseline, policy: policy)
    let workspaceFiles = try fingerprint(root: snapshot.workspaceRoot, policy: policy)
    try validateChanges(plan.changes, snapshot: snapshot, manifest: manifest)
    let id = candidateID ?? UUID().uuidString.lowercased()
    try validateIdentifier(id)
    let parent = try candidateDirectory(workspaceID: plan.id)
    try ensureCandidateCapacity(parent)
    let folder = parent.appendingPathComponent(id, isDirectory: true)
    let metadata = candidateMetadataURL(id: id, parent: parent)
    guard !FileManager.default.fileExists(atPath: folder.path),
      !FileManager.default.fileExists(atPath: metadata.path),
      (try? FileManager.default.destinationOfSymbolicLink(atPath: folder.path)) == nil,
      (try? FileManager.default.destinationOfSymbolicLink(atPath: metadata.path)) == nil
    else { throw AgentWorkspaceError.invalidIdentifier }
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    do {
      let root = try RegisteredRoot(capturing: folder)
      try writeJSON(
        AgentWorkspaceCandidateIdentity(id: id, workspaceID: plan.id, root: root),
        to: metadata)
      try copyCandidateProject(projectFiles, from: snapshot.projectRoot, to: root)
      let resolver = ProjectPathResolver(root: root)
      for change in plan.changes {
        try applyValue(
          change.after, previous: change.before, path: SecureRelativePath(change.path),
          resolver: resolver)
      }
      let candidateFiles = try fingerprint(root: root, policy: policy)
      guard try fingerprint(root: snapshot.projectRoot, policy: policy) == projectFiles,
        try fingerprint(root: baseline, policy: policy) == baselineFiles,
        try fingerprint(root: snapshot.workspaceRoot, policy: policy) == workspaceFiles
      else { throw AgentWorkspaceError.revisionConflict("") }
      return AgentWorkspaceMergeCandidate(
        id: id, workspaceID: plan.id, root: root, revision: plan.revision, changes: plan.changes,
        projectFiles: projectFiles, baselineFiles: baselineFiles, workspaceFiles: workspaceFiles,
        candidateFiles: candidateFiles)
    } catch {
      let failure = error
      do {
        try FileManager.default.removeItem(at: folder)
        if FileManager.default.fileExists(atPath: metadata.path) {
          try FileManager.default.removeItem(at: metadata)
        }
      } catch {
        throw AgentWorkspaceRecoveryFailure(
          paths: [], failureReason: Self.recoveryReason(failure),
          journalFailureReason: Self.recoveryReason(error))
      }
      throw failure
    }
  }

  /// The caller holds both project and root-session write leases for this final recheck and apply.
  public func applyMerge(
    plan: AgentWorkspaceMergePlan, verifiedCandidate candidate: AgentWorkspaceMergeCandidate
  ) throws -> AgentWorkspaceMergeResult {
    try validateCandidate(candidate, plan: plan)
    return try applyMerge(plan: plan)
  }

  public func discardMergeCandidate(_ candidate: AgentWorkspaceMergeCandidate) throws {
    try validateCandidateLocation(candidate)
    try discardMergeCandidate(workspaceID: candidate.workspaceID, candidateID: candidate.id)
  }

  /// Call only after the validation process and its descendants have exited.
  public func discardMergeCandidate(workspaceID: String, candidateID: String) throws {
    try validateIdentifier(workspaceID)
    try validateIdentifier(candidateID)
    guard try snapshot(id: workspaceID) != nil else {
      throw AgentWorkspaceError.workspaceUnavailable
    }
    let parent = try candidateDirectory(workspaceID: workspaceID)
    let folder = parent.appendingPathComponent(candidateID, isDirectory: true)
    let metadata = candidateMetadataURL(id: candidateID, parent: parent)
    guard FileManager.default.fileExists(atPath: metadata.path) else {
      if FileManager.default.fileExists(atPath: folder.path) {
        throw AgentWorkspaceError.invalidStorage
      }
      return
    }
    let identity = try readJSON(
      AgentWorkspaceCandidateIdentity.self, id: workspaceID,
      name: "candidates/\(candidateID).json")
    guard identity.id == candidateID, identity.workspaceID == workspaceID,
      identity.root.canonicalPath == folder.standardizedFileURL.path
    else { throw AgentWorkspaceError.invalidStorage }
    if FileManager.default.fileExists(atPath: folder.path) {
      let actual = try FileSystemEntryMetadata(at: folder)
      guard actual.isDirectory, !actual.isSymbolicLink else {
        throw AgentWorkspaceError.invalidStorage
      }
      try identity.root.validateCurrentIdentity()
      try FileManager.default.removeItem(at: folder)
    } else if (try? FileManager.default.destinationOfSymbolicLink(atPath: folder.path)) != nil {
      throw AgentWorkspaceError.invalidStorage
    }
    try FileManager.default.removeItem(at: metadata)
  }

  private func validateCandidate(
    _ candidate: AgentWorkspaceMergeCandidate, plan: AgentWorkspaceMergePlan
  ) throws {
    guard candidate.workspaceID == plan.id, candidate.revision == plan.revision,
      candidate.changes == plan.changes, plan.conflicts.isEmpty,
      let snapshot = try snapshot(id: plan.id), snapshot.revision == plan.revision
    else { throw AgentWorkspaceError.revisionConflict("") }
    try validateCandidateLocation(candidate)
    let manifest = try readManifest(id: plan.id)
    let policy = ProjectFilePolicy(forbiddenPatterns: manifest.forbiddenPatterns)
    guard try fingerprint(root: snapshot.projectRoot, policy: policy) == candidate.projectFiles,
      try fingerprint(root: baselineRoot(manifest), policy: policy) == candidate.baselineFiles,
      try fingerprint(root: snapshot.workspaceRoot, policy: policy) == candidate.workspaceFiles,
      try fingerprint(root: candidate.root, policy: policy) == candidate.candidateFiles
    else { throw AgentWorkspaceError.revisionConflict("") }
  }

  private func candidateDirectory(workspaceID: String) throws -> URL {
    let parent = workspaceDirectory(workspaceID).appendingPathComponent(
      "candidates", isDirectory: true)
    if !FileManager.default.fileExists(atPath: parent.path) {
      try FileManager.default.createDirectory(
        at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    let metadata = try FileSystemEntryMetadata(at: parent)
    guard metadata.isDirectory, !metadata.isSymbolicLink else {
      throw AgentWorkspaceError.invalidStorage
    }
    return parent
  }

  private func ensureCandidateCapacity(_ directory: URL) throws {
    var entries = Set<String>()
    for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
      let metadata = try FileSystemEntryMetadata(at: directory.appendingPathComponent(name))
      if metadata.isDirectory || metadata.isSymbolicLink {
        entries.insert(name)
      } else if metadata.isRegularFile, name.hasSuffix(".json") {
        entries.insert(String(name.dropLast(5)))
      } else {
        throw AgentWorkspaceError.invalidStorage
      }
      guard entries.count < 2 else { throw AgentWorkspaceError.resourceLimit }
    }
  }

  private func candidateMetadataURL(id: String, parent: URL) -> URL {
    parent.appendingPathComponent("\(id).json")
  }

  private func validateCandidateLocation(_ candidate: AgentWorkspaceMergeCandidate) throws {
    try validateIdentifier(candidate.id)
    try validateIdentifier(candidate.workspaceID)
    guard try snapshot(id: candidate.workspaceID) != nil else {
      throw AgentWorkspaceError.workspaceUnavailable
    }
    let expected = try candidateDirectory(workspaceID: candidate.workspaceID)
      .appendingPathComponent(candidate.id, isDirectory: true)
    let metadata = try FileSystemEntryMetadata(at: expected)
    guard metadata.isDirectory, !metadata.isSymbolicLink,
      expected.standardizedFileURL.path == candidate.root.canonicalPath
    else { throw AgentWorkspaceError.invalidStorage }
    let identity = try readJSON(
      AgentWorkspaceCandidateIdentity.self, id: candidate.workspaceID,
      name: "candidates/\(candidate.id).json")
    guard identity.id == candidate.id, identity.workspaceID == candidate.workspaceID,
      identity.root == candidate.root
    else { throw AgentWorkspaceError.invalidStorage }
    try candidate.root.validateCurrentIdentity()
  }

  private func copyCandidateProject(
    _ files: [String: AgentWorkspaceFileFingerprint], from project: RegisteredRoot,
    to candidate: RegisteredRoot
  ) throws {
    let source = ProjectPathResolver(root: project)
    let destination = ProjectPathResolver(root: candidate)
    for value in files.keys.sorted() {
      try Task.checkCancellation()
      let path = try SecureRelativePath(value)
      guard let expected = files[value],
        let content = try writer.readContent(
          relativePath: path, through: source),
        SecureFileRevision.digest(of: content).sha256 == expected.sha256,
        try AgentWorkspaceInventory.mode(at: project, path: value) == expected.mode
      else { throw AgentWorkspaceError.revisionConflict(value) }
      _ = try writer.write(
        relativePath: path, through: destination, mode: .create, content: content,
        expectedSHA256: nil, createParents: true, allowsBinaryContent: true)
      try AgentWorkspaceInventory.setMode(expected.mode, at: candidate, path: value)
    }
  }

  func fingerprint(root: RegisteredRoot, policy: ProjectFilePolicy) throws
    -> [String: AgentWorkspaceFileFingerprint]
  {
    let inventory = AgentWorkspaceInventory(root: root, policy: policy)
    let paths = try inventory.paths()
    let resolver = ProjectPathResolver(root: root)
    var result: [String: AgentWorkspaceFileFingerprint] = [:]
    for value in paths {
      try Task.checkCancellation()
      let path = try SecureRelativePath(value)
      guard let content = try writer.readContent(relativePath: path, through: resolver) else {
        throw AgentWorkspaceError.revisionConflict(value)
      }
      try AgentWorkspaceInventory.validateContent(content, path: value)
      result[value] = AgentWorkspaceFileFingerprint(
        sha256: SecureFileRevision.digest(of: content).sha256,
        mode: try AgentWorkspaceInventory.mode(at: root, path: value))
    }
    guard try inventory.paths() == paths else { throw AgentWorkspaceError.revisionConflict("") }
    return result
  }
}
