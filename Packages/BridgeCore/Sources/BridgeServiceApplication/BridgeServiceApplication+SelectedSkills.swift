import BridgeAgentCore
import BridgeMCP
import BridgeSecurity
import BridgeServiceCore
import BridgeSkills
import Crypto
import Foundation

extension BridgeServiceApplication {
  func selectedSkillSnapshots(
    for submission: MCPServiceTaskSubmission,
    project: ServiceProjectRecord,
    deadline: ContinuousClock.Instant,
    previousTask: ServiceTaskRecord? = nil
  ) async throws -> [AgentSelectedSkill] {
    guard submission.providerID == "pi" || submission.providerID == "qoder" else { return [] }
    let hasSelection = submission.skillName != nil || submission.skillNames != nil
    if !hasSelection, let previousTask { return previousTask.selectedSkills }
    let names = Array(
      NSOrderedSet(array: (submission.skillNames ?? []) + [submission.skillName].compactMap { $0 })
    )
    .compactMap { $0 as? String }
    guard names.count <= 16, names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else {
      throw BridgeMCPQueryError.contractRejected
    }
    guard !names.isEmpty else { return [] }
    try Self.checkDeadline(deadline)
    let root = URL(fileURLWithPath: project.root.canonicalPath)
    let manifests = try await skillScanner.scanSkills(for: root)
    var result: [AgentSelectedSkill] = []
    result.reserveCapacity(names.count)
    for name in names {
      guard let manifest = manifests.first(where: { $0.name == name }) else {
        throw BridgeMCPQueryError.skillNotFound
      }
      let files = try await skillFiles(manifest)
      let version = SHA256.hash(data: try JSONEncoder().encode(files))
        .map { String(format: "%02x", $0) }.joined()
      result.append(
        try AgentSelectedSkill(
          name: manifest.name,
          source: manifest.scope == .project ? .project : .global,
          contentVersion: version,
          files: files
        ))
    }
    return result
  }

  private func skillFiles(_ manifest: SkillManifest) async throws -> [AgentSelectedSkillFile] {
    let root = URL(fileURLWithPath: manifest.rootPath, isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL
    let paths = try skillResourcePaths(root)
    guard paths.contains("SKILL.md"), paths.count <= 64 else {
      throw BridgeMCPQueryError.contractRejected
    }
    var files: [AgentSelectedSkillFile] = []
    var totalBytes = 0
    for path in paths {
      do {
        let document = try await skillScanner.readSkillDocument(manifest, subpath: path)
        let content = OutboundContentSecurity.redactedSecrets(
          document.content,
          maximumUTF8Bytes: SkillScanner.maximumDocumentBytes
        )
        totalBytes += content.utf8.count
        guard totalBytes <= 512 * 1_024 else { throw BridgeMCPQueryError.contractRejected }
        files.append(try AgentSelectedSkillFile(relativePath: path, content: content))
      } catch SkillError.invalidEncoding {
        continue
      } catch SkillError.documentTooLarge {
        continue
      }
    }
    guard files.contains(where: { $0.relativePath == "SKILL.md" }) else {
      throw BridgeMCPQueryError.skillNotFound
    }
    return files
  }

  private func skillResourcePaths(_ root: URL) throws -> [String] {
    var paths: [String] = []
    var visitedEntries = 0
    try enumerateSkillDirectory(
      root, root: root, depth: 0, visitedEntries: &visitedEntries, paths: &paths)
    return paths.sorted()
  }

  private func enumerateSkillDirectory(
    _ directory: URL,
    root: URL,
    depth: Int,
    visitedEntries: inout Int,
    paths: inout [String]
  ) throws {
    guard depth <= 8, visitedEntries <= 256 else { throw BridgeMCPQueryError.contractRejected }
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    let entries = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: Array(keys),
      options: []
    )
    for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      visitedEntries += 1
      guard visitedEntries <= 256 else { throw BridgeMCPQueryError.contractRejected }
      let values = try entry.resourceValues(forKeys: keys)
      guard values.isSymbolicLink != true else { continue }
      if values.isDirectory == true {
        try enumerateSkillDirectory(
          entry, root: root, depth: depth + 1, visitedEntries: &visitedEntries, paths: &paths)
      } else if values.isRegularFile == true,
        let path = AgentPathSemantics.relativePath(
          entry.resolvingSymlinksInPath().standardizedFileURL.path, from: root.path
        ), !path.isEmpty
      {
        paths.append(path.replacingOccurrences(of: "\\", with: "/"))
      }
    }
  }
}
