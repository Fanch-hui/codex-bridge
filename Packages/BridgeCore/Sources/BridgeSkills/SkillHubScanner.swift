import BridgeAgentCore
import BridgeSecurity
import Foundation

public struct SkillHubScanResult: Sendable {
  public let occurrences: [SkillOccurrence]
  public let sourceStatuses: [SkillHubSourceStatus]
  public let fingerprintedRoots: [String]
}

public struct SkillHubScanner: Sendable {
  private var fileManager: FileManager { .default }

  public init() {}

  public func scan(
    sources: [SkillSourceDefinition],
    policy: SkillHubPolicy
  ) -> SkillHubScanResult {
    var occurrences: [SkillOccurrence] = []
    var statuses: [SkillHubSourceStatus] = []
    var watchedRoots: [String] = []

    for source in sources {
      let enabled = policy.sourceEnabled[source.id] ?? source.defaultEnabled
      let resolvedRoots = effectiveScanRoots(for: source)
      let existsOnDisk = resolvedRoots.contains { isExistingDirectory($0) }
      if enabled {
        watchedRoots.append(contentsOf: source.roots)
        watchedRoots.append(contentsOf: resolvedRoots)
      }

      var discoveredCount = 0
      if enabled {
        let found = scanSource(source, effectiveRoots: resolvedRoots)
        discoveredCount = found.count
        occurrences.append(contentsOf: found)
      }
      statuses.append(
        SkillHubSourceStatus(
          id: source.id,
          displayName: source.displayName,
          kind: source.kind,
          roots: source.roots,
          existsOnDisk: existsOnDisk,
          enabled: enabled,
          priority: source.defaultPriority,
          discoveredCount: discoveredCount,
          isWritable: source.isWritable,
          isOptionalNoise: source.isOptionalNoise,
          isCustom: source.isCustom
        )
      )
    }
    return SkillHubScanResult(
      occurrences: occurrences,
      sourceStatuses: statuses,
      fingerprintedRoots: Array(Set(watchedRoots)).sorted()
    )
  }

  public func rootFingerprint(for roots: [String]) -> String {
    SkillHubHashing.rootFingerprint(for: roots, fileManager: fileManager)
  }

  public static func stripFrontmatter(from text: String) -> String {
    SkillHubHashing.stripFrontmatter(from: text)
  }

  public func effectiveScanRoots(for source: SkillSourceDefinition) -> [String] {
    switch source.scanMode {
    case .standardDirectory, .recursiveSystem:
      return source.roots
    case .claudeInstalledPlugins:
      return claudePluginSkillRoots(configRoots: source.roots)
    case .geminiPlugins:
      return geminiPluginSkillRoots(configRoots: source.roots)
    }
  }

  private func scanSource(
    _ source: SkillSourceDefinition,
    effectiveRoots: [String]
  ) -> [SkillOccurrence] {
    var result: [SkillOccurrence] = []
    var seenEntryPaths = Set<String>()
    for rootPath in effectiveRoots {
      guard isExistingDirectory(rootPath) else { continue }
      let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
      var visitedContainers = Set<String>()
      let items = scanDirectory(
        rootURL,
        source: source,
        depth: 0,
        nestedCollection: false,
        visitedContainers: &visitedContainers
      )
      for item in items where seenEntryPaths.insert(item.entryPath).inserted {
        result.append(item)
        if result.count >= SkillScanner.maximumSkills { return result }
      }
    }
    return result
  }

  private static let excludedContainers: Set<String> = [
    ".git", ".github", "examples", "references", "node_modules", "__pycache__",
  ]

  private func scanDirectory(
    _ directory: URL,
    source: SkillSourceDefinition,
    depth: Int,
    nestedCollection: Bool,
    visitedContainers: inout Set<String>
  ) -> [SkillOccurrence] {
    guard depth <= 4 else { return [] }
    let canonicalContainer = directory.resolvingSymlinksInPath().standardizedFileURL.path
    guard visitedContainers.insert(canonicalContainer).inserted else { return [] }
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil, options: []
      )
    else { return [] }

    var items: [SkillOccurrence] = []
    let sorted = entries.sorted {
      $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent)
        == .orderedAscending
    }
    for entry in sorted {
      let name = entry.lastPathComponent
      guard !Self.excludedContainers.contains(name.lowercased()) else { continue }
      if source.scanMode != .recursiveSystem, name.caseInsensitiveCompare(".system") == .orderedSame
      {
        continue
      }
      guard let metadata = try? FileSystemEntryMetadata(at: entry) else { continue }

      if let resolved = resolveEntry(entry, metadata: metadata) {
        if resolved.isDirectory {
          let skillFile = resolved.target.appendingPathComponent("SKILL.md")
          if fileManager.isReadableFile(atPath: skillFile.path) {
            if let occurrence = parseBundleSkill(
              entry: entry,
              resolvedRoot: resolved.target,
              skillFile: skillFile,
              isSymlink: metadata.isSymbolicLink,
              source: source
            ) {
              items.append(occurrence)
            }
            let nestedSkills = resolved.target.appendingPathComponent("skills", isDirectory: true)
            if isExistingDirectory(nestedSkills.path) {
              items.append(
                contentsOf: scanDirectory(
                  nestedSkills,
                  source: source,
                  depth: depth + 1,
                  nestedCollection: true,
                  visitedContainers: &visitedContainers
                )
              )
            }
            continue
          }
          let allowRecurse =
            nestedCollection || source.scanMode == .recursiveSystem
          if allowRecurse,
            !name.hasPrefix(".") || name.caseInsensitiveCompare(".system") == .orderedSame
          {
            items.append(
              contentsOf: scanDirectory(
                resolved.target,
                source: source,
                depth: depth + 1,
                nestedCollection: true,
                visitedContainers: &visitedContainers
              )
            )
          }
        } else if depth == 0,
          name.lowercased().hasSuffix(".md"),
          name.caseInsensitiveCompare("SKILL.md") != .orderedSame,
          !name.hasPrefix(".")
        {
          if let occurrence = parseFlatSkill(
            entry: entry,
            resolvedFile: resolved.target,
            isSymlink: metadata.isSymbolicLink,
            source: source
          ) {
            items.append(occurrence)
          }
        }
      }
      if items.count >= SkillScanner.maximumSkills { break }
    }
    return items
  }

  private func resolveEntry(
    _ entry: URL,
    metadata: FileSystemEntryMetadata
  ) -> (target: URL, isDirectory: Bool)? {
    if !metadata.isSymbolicLink {
      guard metadata.isDirectory || metadata.isRegularFile else { return nil }
      return (entry.resolvingSymlinksInPath().standardizedFileURL, metadata.isDirectory)
    }
    let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
    guard SkillHubHashing.isSafeResolvedTarget(resolved) else { return nil }
    var isDir: ObjCBool = false
    guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDir) else { return nil }
    if isDir.boolValue { return (resolved, true) }
    guard let targetMeta = try? FileSystemEntryMetadata(at: resolved), targetMeta.isRegularFile
    else {
      return nil
    }
    return (resolved, false)
  }

  private func parseBundleSkill(
    entry: URL,
    resolvedRoot: URL,
    skillFile: URL,
    isSymlink: Bool,
    source: SkillSourceDefinition
  ) -> SkillOccurrence? {
    guard let text = readManifestText(at: skillFile),
      let metadata = try? SkillFrontmatter.parse(text)
    else { return nil }

    let fallbackName = entry.lastPathComponent
    let rawName = SkillManifestMetadata.declaredName(from: metadata, fallback: fallbackName)
    let canonicalSlug = SkillSlugNormalizer.normalize(rawName)
    let body = SkillHubHashing.stripFrontmatter(from: text)
    let declaredDescription = SkillManifestMetadata.description(from: metadata)
    let description =
      declaredDescription.isEmpty
      ? SkillHubHashing.fallbackDescription(fromBody: body, sourceName: source.displayName)
      : declaredDescription
    let whenToUse = metadata.scalar("whenToUse").flatMap { $0.isEmpty ? nil : $0 }
    let policy = invocationPolicy(from: metadata)
    let documentHash = SkillHubHashing.normalizedDocumentHash(text)
    let bundle = SkillHubHashing.bundleSnapshot(
      directory: resolvedRoot, documentHash: documentHash, fileManager: fileManager)
    var actions =
      (try? SkillActionCatalog.actions(
        for: resolvedRoot, metadata: metadata, documentText: text, fileManager: fileManager))
      ?? []
    if actions.isEmpty { actions = SkillActionCatalog.builtInActions(for: canonicalSlug) }

    return SkillOccurrence(
      id: SkillHubHashing.occurrenceID(
        sourceID: source.id, entryPath: entry.standardizedFileURL.path),
      sourceID: source.id,
      sourceName: source.displayName,
      scope: source.kind == .project ? .project : .global,
      entryPath: entry.standardizedFileURL.path,
      canonicalRootPath: resolvedRoot.path,
      entryFilePath: skillFile.path,
      isFlatFile: false,
      isSymlink: isSymlink,
      physicalKey: SkillHubHashing.physicalIdentityKey(for: resolvedRoot, isDirectory: true),
      rawName: rawName,
      canonicalSlug: canonicalSlug,
      description: description,
      whenToUse: whenToUse,
      frontmatterModelInvocable: policy.modelInvocable,
      frontmatterUserInvocable: policy.userInvocable,
      documentHash: documentHash,
      bundleHash: bundle.bundleHash,
      modifiedAt: SkillHubHashing.modifiedTimestamp(at: skillFile, fileManager: fileManager),
      resourceFiles: bundle.resourceFiles,
      hasReferences: bundle.hasReferences,
      triggers: SkillManifestMetadata.triggers(from: metadata),
      actions: actions,
      priorityRank: source.defaultPriority,
      isWritable: source.isWritable,
      isSystemOrPlugin: source.isOptionalNoise
    )
  }

  private func parseFlatSkill(
    entry: URL,
    resolvedFile: URL,
    isSymlink: Bool,
    source: SkillSourceDefinition
  ) -> SkillOccurrence? {
    guard let text = readManifestText(at: resolvedFile),
      let metadata = try? SkillFrontmatter.parse(text)
    else { return nil }

    let fallbackName = entry.deletingPathExtension().lastPathComponent
    let rawName = SkillManifestMetadata.declaredName(from: metadata, fallback: fallbackName)
    let canonicalSlug = SkillSlugNormalizer.normalize(rawName)
    let body = SkillHubHashing.stripFrontmatter(from: text)
    let declaredDescription = SkillManifestMetadata.description(from: metadata)
    let description =
      declaredDescription.isEmpty
      ? SkillHubHashing.fallbackDescription(fromBody: body, sourceName: source.displayName)
      : declaredDescription
    let whenToUse = metadata.scalar("whenToUse").flatMap { $0.isEmpty ? nil : $0 }
    let policy = invocationPolicy(from: metadata)
    let documentHash = SkillHubHashing.normalizedDocumentHash(text)

    return SkillOccurrence(
      id: SkillHubHashing.occurrenceID(
        sourceID: source.id, entryPath: entry.standardizedFileURL.path),
      sourceID: source.id,
      sourceName: source.displayName,
      scope: source.kind == .project ? .project : .global,
      entryPath: entry.standardizedFileURL.path,
      canonicalRootPath: resolvedFile.deletingLastPathComponent().path,
      entryFilePath: resolvedFile.path,
      isFlatFile: true,
      isSymlink: isSymlink,
      physicalKey: SkillHubHashing.physicalIdentityKey(for: resolvedFile, isDirectory: false),
      rawName: rawName,
      canonicalSlug: canonicalSlug,
      description: description,
      whenToUse: whenToUse,
      frontmatterModelInvocable: policy.modelInvocable,
      frontmatterUserInvocable: policy.userInvocable,
      documentHash: documentHash,
      bundleHash: documentHash,
      modifiedAt: SkillHubHashing.modifiedTimestamp(at: resolvedFile, fileManager: fileManager),
      resourceFiles: ["SKILL.md"],
      hasReferences: false,
      triggers: SkillManifestMetadata.triggers(from: metadata),
      actions: [],
      priorityRank: source.defaultPriority,
      isWritable: source.isWritable,
      isSystemOrPlugin: source.isOptionalNoise
    )
  }

  private func readManifestText(at url: URL) -> String? {
    guard fileManager.isReadableFile(atPath: url.path),
      let data = try? Data(contentsOf: url),
      data.count <= SkillScanner.maximumDocumentBytes,
      let text = String(data: data, encoding: .utf8)
    else { return nil }
    return text
  }

  private func invocationPolicy(
    from metadata: SkillFrontmatter.Node
  ) -> (modelInvocable: Bool, userInvocable: Bool) {
    let disableModel = booleanScalar(metadata.scalar("disable-model-invocation")) == true
    let userInvocable = booleanScalar(metadata.scalar("user-invocable")) ?? true
    return (!disableModel, userInvocable)
  }

  private func booleanScalar(_ value: String?) -> Bool? {
    guard let value else { return nil }
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "true", "yes", "1", "on": return true
    case "false", "no", "0", "off": return false
    default: return nil
    }
  }

  private func claudePluginSkillRoots(configRoots: [String]) -> [String] {
    var result: [String] = []
    var seen = Set<String>()
    for configPath in configRoots {
      let configURL = URL(fileURLWithPath: configPath, isDirectory: true)
      let enabled = claudeEnabledPlugins(at: configURL.appendingPathComponent("settings.json"))
      let installedURL = configURL.appendingPathComponent("plugins/installed_plugins.json")
      guard let data = try? Data(contentsOf: installedURL),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let plugins = object["plugins"] as? [String: Any]
      else { continue }
      for (pluginID, entry) in plugins {
        if let enabled, enabled[pluginID] == false { continue }
        let records = (entry as? [[String: Any]]) ?? ([entry as? [String: Any]].compactMap { $0 })
        for record in records {
          guard let installPath = record["installPath"] as? String, !installPath.isEmpty else {
            continue
          }
          let skillsURL = URL(fileURLWithPath: installPath, isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true).standardizedFileURL
          if isExistingDirectory(skillsURL.path), seen.insert(skillsURL.path).inserted {
            result.append(skillsURL.path)
          }
        }
      }
    }
    return result
  }

  private func claudeEnabledPlugins(at url: URL) -> [String: Bool]? {
    guard let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let enabled = object["enabledPlugins"] as? [String: Bool]
    else { return nil }
    return enabled
  }

  private func geminiPluginSkillRoots(configRoots: [String]) -> [String] {
    var result: [String] = []
    var seen = Set<String>()
    for rootPath in configRoots {
      let url = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
      guard isExistingDirectory(url.path) else { continue }
      if url.lastPathComponent == "skills" {
        if seen.insert(url.path).inserted { result.append(url.path) }
        continue
      }
      guard
        let entries = try? fileManager.contentsOfDirectory(
          at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
      else { continue }
      for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let skillsURL = entry.appendingPathComponent("skills", isDirectory: true)
          .standardizedFileURL
        if isExistingDirectory(skillsURL.path), seen.insert(skillsURL.path).inserted {
          result.append(skillsURL.path)
        }
      }
    }
    return result
  }

  private func isExistingDirectory(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
  }
}
