import BridgeAgentCore
import BridgeServiceCore
import BridgeSkills
import Foundation

public struct WorkbenchSkillInvocation: Codable, Equatable, Sendable {
  public let modelInvocable: Bool
  public let userInvocable: Bool
}

public struct WorkbenchSkillResourceBase: Codable, Equatable, Sendable {
  public let kind: String
  public let path: String
}

public struct WorkbenchSkillLocator: Codable, Equatable, Sendable {
  public let slug: String
  public let occurrenceID: String
}

public struct WorkbenchSkillCandidate: Codable, Equatable, Sendable {
  public let name: String
  public let description: String
  public let whenToUse: String?
  public let invocation: WorkbenchSkillInvocation
  public let source: String
  public let provider: String
  public let resourceBase: WorkbenchSkillResourceBase?
  public let path: String
  public let locator: WorkbenchSkillLocator
}

public struct WorkbenchSkillDefinition: Codable, Equatable, Sendable {
  public let name: String
  public let description: String
  public let whenToUse: String?
  public let invocation: WorkbenchSkillInvocation
  public let source: String
  public let provider: String
  public let resourceBase: WorkbenchSkillResourceBase?
  public let path: String
  public let content: String
}

public actor ServiceSkillHub {
  struct CacheEntry {
    let snapshot: SkillHubCatalogSnapshot
    let fingerprintedRoots: [String]
    let fingerprint: String
  }

  let settings: ServiceSettings
  public let libraryStore: SkillLibraryStore
  private let legacyEmbeddedSkillsRoot: URL?
  private let environment: [String: String]
  private let homeDirectory: URL
  private let fixedGlobalRoots: [URL]?
  private let scanner = SkillHubScanner()
  private let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  var policyLoaded = false
  private var legacyAdopted = false
  var cachedPolicy = SkillHubPolicy()
  var revision: UInt64 = 1
  private var cache: [String: CacheEntry] = [:]
  private var onCatalogChanged: (@Sendable () async -> Void)?

  public init(
    settings: ServiceSettings,
    managedSkillsRoot: URL,
    legacyEmbeddedSkillsRoot: URL? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    fixedGlobalRoots: [URL]? = nil
  ) {
    self.settings = settings
    self.libraryStore = SkillLibraryStore(rootURL: managedSkillsRoot)
    self.legacyEmbeddedSkillsRoot = legacyEmbeddedSkillsRoot?.standardizedFileURL
    self.environment = environment
    self.homeDirectory = homeDirectory
    self.fixedGlobalRoots = fixedGlobalRoots
  }

  public func setOnCatalogChanged(_ handler: (@Sendable () async -> Void)?) {
    onCatalogChanged = handler
  }

  public func snapshot(
    projectRoot: URL?,
    projectID: String?,
    forceRefresh: Bool = false
  ) async throws -> SkillHubCatalogSnapshot {
    try await ensureInitialized()
    let key = cacheKey(projectRoot: projectRoot, projectID: projectID)
    if !forceRefresh, let entry = cache[key] {
      let currentFingerprint = scanner.rootFingerprint(for: entry.fingerprintedRoots)
      if currentFingerprint == entry.fingerprint {
        return entry.snapshot
      }
      revision &+= 1
      await notifyCatalogChanged()
    } else if forceRefresh {
      revision &+= 1
    }
    return buildAndCacheSnapshot(projectRoot: projectRoot, projectID: projectID, key: key)
  }

  public func refreshIfDiskChanged(
    for projectRoot: URL?,
    projectID: String? = nil
  ) async {
    guard (try? await ensureInitialized()) != nil else { return }
    let key = cacheKey(projectRoot: projectRoot, projectID: projectID)
    guard let entry = cache[key] else { return }
    let current = scanner.rootFingerprint(for: entry.fingerprintedRoots)
    guard current != entry.fingerprint else { return }
    cache.removeAll()
    revision &+= 1
    await notifyCatalogChanged()
  }

  public func activeManifests(
    for projectRoot: URL?,
    projectID: String? = nil
  ) async throws -> [SkillManifest] {
    let snap = try await snapshot(projectRoot: projectRoot, projectID: projectID)
    return snap.skills.filter { $0.invocationMode != .disabled }.map(\.manifest)
  }

  public func findActiveSkill(
    named nameOrSlug: String,
    projectRoot: URL?,
    projectID: String? = nil
  ) async throws -> ResolvedHubSkill? {
    let snap = try await snapshot(projectRoot: projectRoot, projectID: projectID)
    let active = snap.skills.filter { $0.invocationMode != .disabled }
    if let exactSlug = active.first(where: { $0.canonicalSlug == nameOrSlug }) {
      return exactSlug
    }
    if let exactRaw = active.first(where: { $0.winner.rawName == nameOrSlug }) {
      return exactRaw
    }
    return active.first { skill in
      skill.variants.contains { $0.occurrence.rawName == nameOrSlug }
    }
  }

  public func readDocument(
    skillName: String,
    projectRoot: URL?,
    projectID: String? = nil,
    subpath: String = "SKILL.md"
  ) async throws -> SkillDocument {
    guard
      let skill = try await findActiveSkill(
        named: skillName, projectRoot: projectRoot, projectID: projectID
      )
    else {
      throw SkillError.documentNotFound
    }
    return try SkillDocumentReader.readOccurrence(
      skill.winner,
      slug: skill.canonicalSlug,
      subpath: subpath
    )
  }

  public func workbenchCandidates(
    projectRoot: URL?,
    projectID: String?
  ) async throws -> [WorkbenchSkillCandidate] {
    let snap = try await snapshot(projectRoot: projectRoot, projectID: projectID)
    return snap.skills.compactMap { skill in
      guard skill.invocationMode != .disabled,
        skill.effectiveModelInvocable || skill.effectiveUserInvocable,
        SkillSlugNormalizer.isValidDSHSlug(skill.canonicalSlug),
        !skill.description.isEmpty
      else { return nil }
      return WorkbenchSkillCandidate(
        name: skill.canonicalSlug,
        description: skill.description,
        whenToUse: skill.whenToUse,
        invocation: WorkbenchSkillInvocation(
          modelInvocable: skill.effectiveModelInvocable,
          userInvocable: skill.effectiveUserInvocable
        ),
        source: workbenchSourceLabel(for: skill.winner),
        provider: "bridge",
        resourceBase: WorkbenchSkillResourceBase(
          kind: "directory",
          path: skill.winner.canonicalRootPath
        ),
        path: skill.winner.entryFilePath,
        locator: WorkbenchSkillLocator(
          slug: skill.canonicalSlug,
          occurrenceID: skill.winner.id
        )
      )
    }
  }

  public func workbenchDefinition(
    slug: String,
    occurrenceID: String?,
    projectRoot: URL?,
    projectID: String?
  ) async throws -> WorkbenchSkillDefinition? {
    let snap = try await snapshot(projectRoot: projectRoot, projectID: projectID)
    guard
      let skill = snap.skills.first(where: {
        $0.canonicalSlug == slug && $0.invocationMode != .disabled
      })
    else { return nil }
    let target =
      occurrenceID.flatMap { id in
        skill.variants.first(where: { $0.occurrence.id == id })?.occurrence
      } ?? skill.winner
    guard
      let document = try? SkillDocumentReader.readOccurrence(
        target, slug: skill.canonicalSlug, subpath: "SKILL.md"
      )
    else { return nil }
    let body = SkillHubScanner.stripFrontmatter(from: document.content)
    return WorkbenchSkillDefinition(
      name: skill.canonicalSlug,
      description: skill.description,
      whenToUse: skill.whenToUse,
      invocation: WorkbenchSkillInvocation(
        modelInvocable: skill.effectiveModelInvocable,
        userInvocable: skill.effectiveUserInvocable
      ),
      source: workbenchSourceLabel(for: target),
      provider: "bridge",
      resourceBase: WorkbenchSkillResourceBase(kind: "directory", path: target.canonicalRootPath),
      path: target.entryFilePath,
      content: body
    )
  }

  func ensureInitialized() async throws {
    if !legacyAdopted {
      legacyAdopted = true
      libraryStore.adoptLegacySkillsIfNeeded(from: legacyEmbeddedSkillsRoot)
    }
    guard !policyLoaded else { return }
    if let raw = try await settings.string(for: .skillHubPolicy),
      let data = raw.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(SkillHubPolicy.self, from: data)
    {
      cachedPolicy = decoded
    }
    policyLoaded = true
  }

  func savePolicyAndInvalidate(_ updated: SkillHubPolicy) async throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(updated)
    let json = String(decoding: data, as: UTF8.self)
    try await settings.set(json, for: .skillHubPolicy)
    cachedPolicy = updated
    policyLoaded = true
    cache.removeAll()
    revision &+= 1
    await notifyCatalogChanged()
  }

  func invalidateAndNotify() async {
    cache.removeAll()
    revision &+= 1
    await notifyCatalogChanged()
  }

  private func notifyCatalogChanged() async {
    await onCatalogChanged?()
  }

  private func buildAndCacheSnapshot(
    projectRoot: URL?,
    projectID: String?,
    key: String
  ) -> SkillHubCatalogSnapshot {
    let projectSources = projectRoot.map { SkillSourceCatalog.projectSources(for: $0) } ?? []
    let globalSources = SkillSourceCatalog.globalSources(
      managedSkillsRoot: libraryStore.rootURL,
      policy: cachedPolicy,
      environment: environment,
      homeDirectory: homeDirectory,
      fixedGlobalRoots: fixedGlobalRoots
    )
    let scanResult = scanner.scan(sources: projectSources + globalSources, policy: cachedPolicy)
    let resolved = SkillHubDeduplicator.resolve(
      occurrences: scanResult.occurrences,
      policy: cachedPolicy,
      projectID: projectID
    )
    let enabledCount = resolved.filter { $0.invocationMode != .disabled }.count
    let modelSkills = resolved.filter(\.effectiveModelInvocable)
    let estimatedBytes = modelSkills.reduce(0) { partial, item in
      partial + "- `\(item.canonicalSlug)`: \(item.description)\n".utf8.count
    }
    let conflictCount = resolved.filter(\.hasConflict).count
    let snapshot = SkillHubCatalogSnapshot(
      revision: revision,
      scannedAt: isoFormatter.string(from: Date()),
      projectID: projectID,
      sources: scanResult.sourceStatuses,
      skills: resolved,
      enabledCount: enabledCount,
      modelInvocableCount: modelSkills.count,
      estimatedCatalogBytes: estimatedBytes,
      conflictCount: conflictCount,
      managedLibraryPath: libraryStore.rootURL.path
    )
    let fingerprint = scanner.rootFingerprint(for: scanResult.fingerprintedRoots)
    cache[key] = CacheEntry(
      snapshot: snapshot,
      fingerprintedRoots: scanResult.fingerprintedRoots,
      fingerprint: fingerprint
    )
    return snapshot
  }

  private func cacheKey(projectRoot: URL?, projectID: String?) -> String {
    let rootKey = projectRoot?.standardizedFileURL.path ?? ""
    let idKey = projectID ?? ""
    return "\(idKey)|\(rootKey)"
  }

  private func workbenchSourceLabel(for occurrence: SkillOccurrence) -> String {
    if occurrence.scope == .project {
      return occurrence.sourceID == "project-dsh" ? "project-dsh" : "project-agents"
    }
    if occurrence.sourceID == "bridge-managed" || occurrence.sourceID == "dsh" {
      return "user-dsh"
    }
    if occurrence.sourceID == "agents-shared" {
      return "user-agents"
    }
    return "custom"
  }
}
