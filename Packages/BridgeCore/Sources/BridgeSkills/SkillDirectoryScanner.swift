import Foundation

struct SkillDirectoryScanner {
  private let globalRoots: [URL]
  private let fileManager: FileManager

  init(globalRoots: [URL], fileManager: FileManager) {
    self.globalRoots = globalRoots
    self.fileManager = fileManager
  }

  func scan(projectRoot: URL?) throws -> [SkillManifest] {
    var result: [SkillManifest] = []
    var names = Set<String>()
    if let projectRoot {
      let root = projectRoot.standardizedFileURL
      for directory in ["skills", ".agents/skills", ".codex/skills"] {
        try append(
          scanDirectory(root.appendingPathComponent(directory), scope: .project),
          to: &result,
          names: &names
        )
      }
    }
    for root in globalRoots {
      try append(scanDirectory(root, scope: .global), to: &result, names: &names)
    }
    return result.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  private func scanDirectory(_ directory: URL, scope: SkillScope) throws -> [SkillManifest] {
    guard fileManager.fileExists(atPath: directory.path) else { return [] }
    let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
    let discovered = try scanCollection(
      directory,
      collectionRoot: resolvedDirectory,
      scope: scope,
      depth: 0,
      traversal: .collectionRoot
    )
    return discovered.sorted {
      if $0.depth != $1.depth { return $0.depth < $1.depth }
      return $0.manifest.rootPath.localizedCaseInsensitiveCompare($1.manifest.rootPath)
        == .orderedAscending
    }.map(\.manifest)
  }

  private struct DiscoveredManifest {
    let manifest: SkillManifest
    let depth: Int
  }

  private enum Traversal: Equatable {
    case collectionRoot
    case nestedCollection
  }

  private static let excludedContainerNames: Set<String> = [
    ".git", ".github", "examples", "references",
  ]

  private func scanCollection(
    _ directory: URL,
    collectionRoot: URL,
    scope: SkillScope,
    depth: Int,
    traversal: Traversal
  ) throws -> [DiscoveredManifest] {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
    if depth > 0 {
      let values = try directory.resourceValues(forKeys: Set(keys))
      guard values.isDirectory == true, values.isSymbolicLink != true else { return [] }
    }
    let entries = try fileManager.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: keys, options: []
    )
    var manifests: [DiscoveredManifest] = []
    for entry in entries.sorted(by: {
      $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent)
        == .orderedAscending
    }) {
      let values = try entry.resourceValues(forKeys: Set(keys))
      guard values.isDirectory == true else { continue }
      let name = entry.lastPathComponent
      guard SkillManifestMetadata.isValidSkillName(name), values.isSymbolicLink != true else {
        continue
      }
      guard !Self.excludedContainerNames.contains(name.lowercased()) else { continue }
      let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
      guard SkillPathRules.isContained(resolved, in: collectionRoot) else { continue }
      let document = entry.appendingPathComponent("SKILL.md")
      if fileManager.fileExists(atPath: document.path) {
        guard let manifest = try readManifest(at: entry, resolved: resolved, scope: scope) else {
          continue
        }
        manifests.append(DiscoveredManifest(manifest: manifest, depth: depth))
        if manifests.count >= SkillScanner.maximumSkills {
          throw SkillError.tooManySkills
        }
        let nestedSkills = entry.appendingPathComponent("skills", isDirectory: true)
        if fileManager.fileExists(atPath: nestedSkills.path) {
          manifests.append(
            contentsOf: try scanCollection(
              nestedSkills,
              collectionRoot: collectionRoot,
              scope: scope,
              depth: depth + 1,
              traversal: .nestedCollection
            ))
          if manifests.count >= SkillScanner.maximumSkills {
            throw SkillError.tooManySkills
          }
        }
        continue
      }

      guard
        traversal == .nestedCollection
          || name.caseInsensitiveCompare(".system") == .orderedSame
      else { continue }
      manifests.append(
        contentsOf: try scanCollection(
          entry,
          collectionRoot: collectionRoot,
          scope: scope,
          depth: depth + 1,
          traversal: .nestedCollection
        ))
      if manifests.count >= SkillScanner.maximumSkills {
        throw SkillError.tooManySkills
      }
    }
    return manifests
  }

  private func readManifest(
    at directory: URL, resolved: URL, scope: SkillScope
  ) throws -> SkillManifest? {
    let document = directory.appendingPathComponent("SKILL.md")
    guard fileManager.isReadableFile(atPath: document.path),
      let data = try? Data(contentsOf: document),
      data.count <= SkillScanner.maximumDocumentBytes,
      let text = String(data: data, encoding: .utf8),
      let metadata = try? SkillFrontmatter.parse(text)
    else { return nil }
    let name = SkillManifestMetadata.declaredName(
      from: metadata, fallback: directory.lastPathComponent)
    var actions = try SkillActionCatalog.actions(
      for: directory, metadata: metadata, documentText: text, fileManager: fileManager)
    if actions.isEmpty { actions = SkillActionCatalog.builtInActions(for: name) }
    return SkillManifest(
      name: name,
      description: SkillManifestMetadata.description(from: metadata),
      scope: scope,
      rootPath: resolved.path,
      triggers: SkillManifestMetadata.triggers(from: metadata),
      actions: actions,
      hasReferences: fileManager.fileExists(
        atPath: directory.appendingPathComponent("references").path)
    )
  }

  private func append(
    _ items: [SkillManifest],
    to result: inout [SkillManifest],
    names: inout Set<String>
  ) throws {
    for item in items where !names.contains(item.name) {
      guard result.count < SkillScanner.maximumSkills else { throw SkillError.tooManySkills }
      result.append(item)
      names.insert(item.name)
    }
  }
}
