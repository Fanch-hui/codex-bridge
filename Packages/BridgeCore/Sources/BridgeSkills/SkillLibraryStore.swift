import BridgeAgentCore
import BridgeSecurity
import Foundation

public struct SkillLibraryStore: Sendable {
  public static let maximumFiles = 2_000
  public static let maximumBytes = 50 * 1_024 * 1_024

  public let rootURL: URL
  private var fileManager: FileManager { .default }

  public init(rootURL: URL) {
    self.rootURL = rootURL.standardizedFileURL
  }

  public func ensureDirectory() throws {
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
  }

  /// One-time non-destructive copy from legacy `<embeddedDSHRoot>/skills` into `<DataRoot>/Skills`.
  public func adoptLegacySkillsIfNeeded(from legacyRoot: URL?) {
    guard let legacyRoot = legacyRoot?.standardizedFileURL,
      legacyRoot.path != rootURL.path,
      isDirectory(legacyRoot)
    else { return }
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: legacyRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
      )
    else { return }
    try? ensureDirectory()
    for entry in entries {
      guard let meta = try? FileSystemEntryMetadata(at: entry), !meta.isSymbolicLink else {
        continue
      }
      if meta.isDirectory, isReadableFile(entry.appendingPathComponent("SKILL.md")) {
        let slug = SkillSlugNormalizer.normalize(entry.lastPathComponent)
        let target = rootURL.appendingPathComponent(slug, isDirectory: true)
        if !fileManager.fileExists(atPath: target.path) {
          _ = try? installDirectorySkill(from: entry, targetName: slug, allowReplace: false)
        }
      }
    }
  }

  public func importFromPath(_ sourceURL: URL) throws -> [SkillLibraryImportItem] {
    let cleanSource = sourceURL.standardizedFileURL
    guard AgentPathSemantics.isAbsolute(cleanSource.path) else {
      throw SkillHubError.invalidPath
    }
    guard let meta = try? FileSystemEntryMetadata(at: cleanSource) else {
      throw SkillHubError.invalidPath
    }
    try ensureDirectory()

    if meta.isRegularFile, cleanSource.pathExtension.lowercased() == "md" {
      let item = try importFlatMarkdown(cleanSource)
      return [item]
    }
    guard meta.isDirectory else {
      throw SkillHubError.invalidManifest("请选择技能文件夹或包含技能的上级文件夹。")
    }

    let sources = try discoverImportSources(at: cleanSource)
    var budget = (files: 0, bytes: 0)
    for source in sources {
      try measure(directory: source, budget: &budget)
    }
    var imported: [SkillLibraryImportItem] = []
    for source in sources {
      let parsedName = readDeclaredOrFolderName(at: source)
      let slug = SkillSlugNormalizer.normalize(parsedName)
      let replaced = try installDirectorySkill(from: source, targetName: slug, allowReplace: true)
      imported.append(SkillLibraryImportItem(name: parsedName, slug: slug, replaced: replaced))
    }
    return imported
  }

  public func forkOccurrence(_ occurrence: SkillOccurrence, newName: String) throws -> String {
    let slug = SkillSlugNormalizer.normalize(newName)
    guard SkillSlugNormalizer.isValidDSHSlug(slug),
      !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw SkillHubError.invalidName("请输入有效的技能名称。")
    }
    try ensureDirectory()
    let target = rootURL.appendingPathComponent(slug, isDirectory: true)
    guard !fileManager.fileExists(atPath: target.path) else {
      throw SkillHubError.invalidName("自管库中已存在同名技能「\(slug)」。")
    }

    let staging = rootURL.appendingPathComponent(".fork-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: staging) }

    if occurrence.isFlatFile {
      try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
      let rawText = try readUTF8(at: URL(fileURLWithPath: occurrence.entryFilePath))
      let rewritten = rewriteFrontmatterName(in: rawText, newName: slug)
      try Data(rewritten.utf8).write(to: staging.appendingPathComponent("SKILL.md"))
    } else {
      let sourceDir = URL(fileURLWithPath: occurrence.canonicalRootPath, isDirectory: true)
      var budget = (files: 0, bytes: 0)
      try measure(directory: sourceDir, budget: &budget)
      try copyDirectorySkippingSymlinks(from: sourceDir, to: staging)
      let manifestURL = staging.appendingPathComponent("SKILL.md")
      if fileManager.fileExists(atPath: manifestURL.path) {
        let rawText = try readUTF8(at: manifestURL)
        let rewritten = rewriteFrontmatterName(in: rawText, newName: slug)
        try Data(rewritten.utf8).write(to: manifestURL)
      }
    }

    try fileManager.moveItem(at: staging, to: target)
    return slug
  }

  public func renameManagedSkill(canonicalPath: String, newName: String) throws -> String {
    let source = try validateManagedChild(path: canonicalPath)
    let newSlug = SkillSlugNormalizer.normalize(newName)
    guard SkillSlugNormalizer.isValidDSHSlug(newSlug),
      !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw SkillHubError.invalidName("请输入有效的技能名称。")
    }
    let destination = rootURL.appendingPathComponent(newSlug, isDirectory: true)
    guard destination.standardizedFileURL.path != source.standardizedFileURL.path else {
      return newSlug
    }
    guard !fileManager.fileExists(atPath: destination.path) else {
      throw SkillHubError.invalidName("自管库中已存在同名技能「\(newSlug)」。")
    }
    let manifestURL = source.appendingPathComponent("SKILL.md")
    if fileManager.fileExists(atPath: manifestURL.path) {
      let rawText = try readUTF8(at: manifestURL)
      let updated = rewriteFrontmatterName(in: rawText, newName: newSlug)
      try Data(updated.utf8).write(to: manifestURL)
    }
    try fileManager.moveItem(at: source, to: destination)
    return newSlug
  }

  public func deleteManagedSkill(canonicalPath: String) throws {
    let target = try validateManagedChild(path: canonicalPath)
    try fileManager.removeItem(at: target)
  }

  private func validateManagedChild(path: String) throws -> URL {
    let cleanRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
    let candidate = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
    guard SkillPathRules.isContained(candidate, in: cleanRoot),
      candidate.path != cleanRoot.path,
      fileManager.fileExists(atPath: candidate.path)
    else {
      throw SkillHubError.readOnlySource
    }
    return candidate
  }

  private func importFlatMarkdown(_ fileURL: URL) throws -> SkillLibraryImportItem {
    let raw = try readUTF8(at: fileURL)
    guard let parsed = parseFrontmatter(raw) else {
      throw SkillHubError.invalidManifest("\(fileURL.lastPathComponent) 缺少有效的 YAML frontmatter。")
    }
    let fallback = fileURL.deletingPathExtension().lastPathComponent
    let rawName = parsed.scalar("name") ?? fallback
    let slug = SkillSlugNormalizer.normalize(rawName)
    let target = rootURL.appendingPathComponent(slug, isDirectory: true)
    let staging = rootURL.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: staging) }
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    let rewritten = rewriteFrontmatterName(in: raw, newName: slug)
    try Data(rewritten.utf8).write(to: staging.appendingPathComponent("SKILL.md"))
    let replaced = try swapStaging(staging, into: target)
    return SkillLibraryImportItem(name: rawName, slug: slug, replaced: replaced)
  }

  private func discoverImportSources(at directory: URL) throws -> [URL] {
    if try validateSkillFolder(directory) {
      return [directory]
    }
    let children = try fileManager.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    var found: [URL] = []
    for child in children {
      guard let meta = try? FileSystemEntryMetadata(at: child),
        meta.isDirectory, !meta.isSymbolicLink
      else { continue }
      if try validateSkillFolder(child) { found.append(child) }
    }
    guard !found.isEmpty else {
      throw SkillHubError.invalidManifest("所选文件夹及其下一层都没有有效的 SKILL.md。")
    }
    return found
  }

  private func validateSkillFolder(_ directory: URL) throws -> Bool {
    let manifest = directory.appendingPathComponent("SKILL.md")
    guard fileManager.fileExists(atPath: manifest.path) else { return false }
    let text = try readUTF8(at: manifest)
    guard let parsed = parseFrontmatter(text) else {
      throw SkillHubError.invalidManifest(
        "\(directory.lastPathComponent)/SKILL.md 缺少有效的 frontmatter。")
    }
    let hasName = !(parsed.scalar("name") ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    let hasDesc = !(parsed.scalar("description") ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    guard hasName || !directory.lastPathComponent.isEmpty else {
      throw SkillHubError.invalidManifest("\(directory.lastPathComponent)/SKILL.md 缺少 name。")
    }
    let body = SkillHubHashing.stripFrontmatter(from: text)
    guard hasDesc || !body.isEmpty else {
      throw SkillHubError.invalidManifest(
        "\(directory.lastPathComponent)/SKILL.md 缺少 description 或正文。")
    }
    return true
  }

  private func readDeclaredOrFolderName(at directory: URL) -> String {
    let manifest = directory.appendingPathComponent("SKILL.md")
    if let text = try? readUTF8(at: manifest),
      let parsed = parseFrontmatter(text),
      let declared = parsed.scalar("name")?.trimmingCharacters(in: .whitespacesAndNewlines),
      !declared.isEmpty
    {
      return declared
    }
    return directory.lastPathComponent
  }

  private func parseFrontmatter(_ text: String) -> SkillFrontmatter.Node? {
    (try? SkillFrontmatter.parse(text)) ?? nil
  }

  private func installDirectorySkill(
    from source: URL,
    targetName: String,
    allowReplace: Bool
  ) throws -> Bool {
    let target = rootURL.appendingPathComponent(targetName, isDirectory: true)
    if !allowReplace, fileManager.fileExists(atPath: target.path) { return false }
    let staging = rootURL.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: staging) }
    try copyDirectorySkippingSymlinks(from: source, to: staging)
    return try swapStaging(staging, into: target)
  }

  private func swapStaging(_ staging: URL, into target: URL) throws -> Bool {
    let replaced = fileManager.fileExists(atPath: target.path)
    let backup = rootURL.appendingPathComponent(".previous-\(UUID().uuidString)", isDirectory: true)
    if replaced {
      try fileManager.moveItem(at: target, to: backup)
    }
    do {
      try fileManager.moveItem(at: staging, to: target)
      if replaced { try? fileManager.removeItem(at: backup) }
      return replaced
    } catch {
      if replaced, !fileManager.fileExists(atPath: target.path) {
        try? fileManager.moveItem(at: backup, to: target)
      }
      throw error
    }
  }

  private func measure(directory: URL, budget: inout (files: Int, bytes: Int)) throws {
    let entries = try fileManager.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil, options: []
    )
    for entry in entries {
      guard let meta = try? FileSystemEntryMetadata(at: entry), !meta.isSymbolicLink else {
        continue
      }
      if meta.isDirectory {
        try measure(directory: entry, budget: &budget)
      } else if meta.isRegularFile {
        budget.files += 1
        budget.bytes += meta.fileSize ?? 0
        if budget.files > Self.maximumFiles || budget.bytes > Self.maximumBytes {
          throw SkillHubError.sizeLimitExceeded
        }
      }
    }
  }

  private func copyDirectorySkippingSymlinks(from source: URL, to destination: URL) throws {
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    let entries = try fileManager.contentsOfDirectory(
      at: source, includingPropertiesForKeys: nil, options: []
    )
    for entry in entries {
      guard let meta = try? FileSystemEntryMetadata(at: entry), !meta.isSymbolicLink else {
        continue
      }
      let next = destination.appendingPathComponent(entry.lastPathComponent)
      if meta.isDirectory {
        try copyDirectorySkippingSymlinks(from: entry, to: next)
      } else if meta.isRegularFile {
        try fileManager.copyItem(at: entry, to: next)
      }
    }
  }

  private func rewriteFrontmatterName(in text: String, newName: String) -> String {
    var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
      .map(String.init)
    guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
      let end = lines.dropFirst().firstIndex(where: {
        $0.trimmingCharacters(in: .whitespaces) == "---"
      })
    else {
      return "---\nname: \(newName)\ndescription: \(newName)\n---\n\n\(text)"
    }
    if let nameIndex = lines[1..<end].firstIndex(where: {
      $0.trimmingCharacters(in: .whitespaces).hasPrefix("name:")
    }) {
      lines[nameIndex] = "name: \(newName)"
    } else {
      lines.insert("name: \(newName)", at: 1)
    }
    return lines.joined(separator: "\n")
  }

  private func readUTF8(at url: URL) throws -> String {
    guard let data = try? Data(contentsOf: url), data.count <= SkillScanner.maximumDocumentBytes,
      let text = String(data: data, encoding: .utf8)
    else {
      throw SkillHubError.invalidManifest("\(url.lastPathComponent) 无法读取或编码无效。")
    }
    return text
  }

  private func isDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
  }

  private func isReadableFile(_ url: URL) -> Bool {
    fileManager.isReadableFile(atPath: url.path)
  }
}
