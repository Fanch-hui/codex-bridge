import Foundation

public enum SkillSourceKind: String, Codable, Sendable {
  case project
  case bridgeManaged = "bridge_managed"
  case agentsShared = "agents_shared"
  case codex
  case claudeCode = "claude_code"
  case dsh
  case openCode = "opencode"
  case geminiAntigravity = "gemini_antigravity"
  case pi
  case qoder
  case cursor
  case devin
  case windsurf
  case custom
  case systemOrPlugin = "system_or_plugin"
}

public enum SkillSourceScanMode: String, Codable, Sendable {
  case standardDirectory
  case recursiveSystem
  case claudeInstalledPlugins
  case geminiPlugins
}

public struct SkillSourceDefinition: Equatable, Sendable {
  public let id: String
  public let displayName: String
  public let kind: SkillSourceKind
  public let roots: [String]
  public let defaultPriority: Int
  public let defaultEnabled: Bool
  public let isWritable: Bool
  public let isOptionalNoise: Bool
  public let isCustom: Bool
  public let scanMode: SkillSourceScanMode

  public init(
    id: String,
    displayName: String,
    kind: SkillSourceKind,
    roots: [String],
    defaultPriority: Int,
    defaultEnabled: Bool,
    isWritable: Bool = false,
    isOptionalNoise: Bool = false,
    isCustom: Bool = false,
    scanMode: SkillSourceScanMode = .standardDirectory
  ) {
    self.id = id
    self.displayName = displayName
    self.kind = kind
    self.roots = roots
    self.defaultPriority = defaultPriority
    self.defaultEnabled = defaultEnabled
    self.isWritable = isWritable
    self.isOptionalNoise = isOptionalNoise
    self.isCustom = isCustom
    self.scanMode = scanMode
  }
}

public enum SkillInvocationMode: String, Codable, CaseIterable, Sendable {
  case autoAndManual = "auto_and_manual"
  case manualOnly = "manual_only"
  case disabled = "disabled"
}

public struct SkillOccurrence: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let sourceID: String
  public let sourceName: String
  public let scope: SkillScope
  public let entryPath: String
  public let canonicalRootPath: String
  public let entryFilePath: String
  public let isFlatFile: Bool
  public let isSymlink: Bool
  public let physicalKey: String
  public let rawName: String
  public let canonicalSlug: String
  public let description: String
  public let whenToUse: String?
  public let frontmatterModelInvocable: Bool
  public let frontmatterUserInvocable: Bool
  public let documentHash: String
  public let bundleHash: String
  public let modifiedAt: String?
  public let resourceFiles: [String]
  public let hasReferences: Bool
  public let triggers: [String]
  public let actions: [SkillAction]
  public let priorityRank: Int
  public let isWritable: Bool
  public let isSystemOrPlugin: Bool

  public init(
    id: String,
    sourceID: String,
    sourceName: String,
    scope: SkillScope,
    entryPath: String,
    canonicalRootPath: String,
    entryFilePath: String,
    isFlatFile: Bool,
    isSymlink: Bool,
    physicalKey: String,
    rawName: String,
    canonicalSlug: String,
    description: String,
    whenToUse: String? = nil,
    frontmatterModelInvocable: Bool = true,
    frontmatterUserInvocable: Bool = true,
    documentHash: String,
    bundleHash: String,
    modifiedAt: String? = nil,
    resourceFiles: [String] = [],
    hasReferences: Bool = false,
    triggers: [String] = [],
    actions: [SkillAction] = [],
    priorityRank: Int,
    isWritable: Bool,
    isSystemOrPlugin: Bool
  ) {
    self.id = id
    self.sourceID = sourceID
    self.sourceName = sourceName
    self.scope = scope
    self.entryPath = entryPath
    self.canonicalRootPath = canonicalRootPath
    self.entryFilePath = entryFilePath
    self.isFlatFile = isFlatFile
    self.isSymlink = isSymlink
    self.physicalKey = physicalKey
    self.rawName = rawName
    self.canonicalSlug = canonicalSlug
    self.description = description
    self.whenToUse = whenToUse
    self.frontmatterModelInvocable = frontmatterModelInvocable
    self.frontmatterUserInvocable = frontmatterUserInvocable
    self.documentHash = documentHash
    self.bundleHash = bundleHash
    self.modifiedAt = modifiedAt
    self.resourceFiles = resourceFiles
    self.hasReferences = hasReferences
    self.triggers = triggers
    self.actions = actions
    self.priorityRank = priorityRank
    self.isWritable = isWritable
    self.isSystemOrPlugin = isSystemOrPlugin
  }
}

public enum SkillDedupRelation: String, Codable, Sendable {
  case winner
  case samePhysical = "same_physical"
  case sameContent = "same_content"
  case overriddenByProject = "overridden_by_project"
  case conflict
}

public struct SkillVariantView: Codable, Equatable, Identifiable, Sendable {
  public var id: String { occurrence.id }
  public let occurrence: SkillOccurrence
  public let relation: SkillDedupRelation
  public let isPinned: Bool

  public init(occurrence: SkillOccurrence, relation: SkillDedupRelation, isPinned: Bool) {
    self.occurrence = occurrence
    self.relation = relation
    self.isPinned = isPinned
  }
}

public struct ResolvedHubSkill: Codable, Equatable, Identifiable, Sendable {
  public var id: String { canonicalSlug }
  public let canonicalSlug: String
  public let displayName: String
  public let description: String
  public let whenToUse: String?
  public let scope: SkillScope
  public let winner: SkillOccurrence
  public let variants: [SkillVariantView]
  public let mergedSourceNames: [String]
  public let hasConflict: Bool
  public let conflictCount: Int
  public let hasProjectOverride: Bool
  public let invocationMode: SkillInvocationMode
  public let effectiveModelInvocable: Bool
  public let effectiveUserInvocable: Bool
  public let pinnedOccurrenceID: String?
  public let projectOverrideMode: SkillInvocationMode?
  public let manifest: SkillManifest

  public init(
    canonicalSlug: String,
    displayName: String,
    description: String,
    whenToUse: String?,
    scope: SkillScope,
    winner: SkillOccurrence,
    variants: [SkillVariantView],
    mergedSourceNames: [String],
    hasConflict: Bool,
    conflictCount: Int,
    hasProjectOverride: Bool,
    invocationMode: SkillInvocationMode,
    effectiveModelInvocable: Bool,
    effectiveUserInvocable: Bool,
    pinnedOccurrenceID: String?,
    projectOverrideMode: SkillInvocationMode?,
    manifest: SkillManifest
  ) {
    self.canonicalSlug = canonicalSlug
    self.displayName = displayName
    self.description = description
    self.whenToUse = whenToUse
    self.scope = scope
    self.winner = winner
    self.variants = variants
    self.mergedSourceNames = mergedSourceNames
    self.hasConflict = hasConflict
    self.conflictCount = conflictCount
    self.hasProjectOverride = hasProjectOverride
    self.invocationMode = invocationMode
    self.effectiveModelInvocable = effectiveModelInvocable
    self.effectiveUserInvocable = effectiveUserInvocable
    self.pinnedOccurrenceID = pinnedOccurrenceID
    self.projectOverrideMode = projectOverrideMode
    self.manifest = manifest
  }
}

public struct SkillCustomDirectory: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let path: String
  public var enabled: Bool

  public init(id: String, name: String, path: String, enabled: Bool = true) {
    self.id = id
    self.name = name
    self.path = path
    self.enabled = enabled
  }
}

public struct SkillItemPolicy: Codable, Equatable, Sendable {
  public var invocationMode: SkillInvocationMode?
  public var pinnedOccurrenceID: String?

  public init(invocationMode: SkillInvocationMode? = nil, pinnedOccurrenceID: String? = nil) {
    self.invocationMode = invocationMode
    self.pinnedOccurrenceID = pinnedOccurrenceID
  }
}

public struct SkillHubPolicy: Codable, Equatable, Sendable {
  public var version: Int
  public var sourceEnabled: [String: Bool]
  public var sourceOrder: [String]
  public var customDirectories: [SkillCustomDirectory]
  public var skillPolicies: [String: SkillItemPolicy]
  public var projectSkillOverrides: [String: [String: SkillInvocationMode]]

  public init(
    version: Int = 1,
    sourceEnabled: [String: Bool] = [:],
    sourceOrder: [String] = [],
    customDirectories: [SkillCustomDirectory] = [],
    skillPolicies: [String: SkillItemPolicy] = [:],
    projectSkillOverrides: [String: [String: SkillInvocationMode]] = [:]
  ) {
    self.version = version
    self.sourceEnabled = sourceEnabled
    self.sourceOrder = sourceOrder
    self.customDirectories = customDirectories
    self.skillPolicies = skillPolicies
    self.projectSkillOverrides = projectSkillOverrides
  }
}

public struct SkillHubSourceStatus: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let displayName: String
  public let kind: SkillSourceKind
  public let roots: [String]
  public let existsOnDisk: Bool
  public let enabled: Bool
  public let priority: Int
  public let discoveredCount: Int
  public let isWritable: Bool
  public let isOptionalNoise: Bool
  public let isCustom: Bool

  public init(
    id: String,
    displayName: String,
    kind: SkillSourceKind,
    roots: [String],
    existsOnDisk: Bool,
    enabled: Bool,
    priority: Int,
    discoveredCount: Int,
    isWritable: Bool,
    isOptionalNoise: Bool,
    isCustom: Bool
  ) {
    self.id = id
    self.displayName = displayName
    self.kind = kind
    self.roots = roots
    self.existsOnDisk = existsOnDisk
    self.enabled = enabled
    self.priority = priority
    self.discoveredCount = discoveredCount
    self.isWritable = isWritable
    self.isOptionalNoise = isOptionalNoise
    self.isCustom = isCustom
  }
}

public struct SkillHubCatalogSnapshot: Codable, Equatable, Sendable {
  public let revision: UInt64
  public let scannedAt: String
  public let projectID: String?
  public let sources: [SkillHubSourceStatus]
  public let skills: [ResolvedHubSkill]
  public let enabledCount: Int
  public let modelInvocableCount: Int
  public let estimatedCatalogBytes: Int
  public let conflictCount: Int
  public let managedLibraryPath: String

  public init(
    revision: UInt64,
    scannedAt: String,
    projectID: String?,
    sources: [SkillHubSourceStatus],
    skills: [ResolvedHubSkill],
    enabledCount: Int,
    modelInvocableCount: Int,
    estimatedCatalogBytes: Int,
    conflictCount: Int,
    managedLibraryPath: String
  ) {
    self.revision = revision
    self.scannedAt = scannedAt
    self.projectID = projectID
    self.sources = sources
    self.skills = skills
    self.enabledCount = enabledCount
    self.modelInvocableCount = modelInvocableCount
    self.estimatedCatalogBytes = estimatedCatalogBytes
    self.conflictCount = conflictCount
    self.managedLibraryPath = managedLibraryPath
  }
}

public struct SkillLibraryImportItem: Codable, Equatable, Sendable {
  public let name: String
  public let slug: String
  public let replaced: Bool

  public init(name: String, slug: String, replaced: Bool) {
    self.name = name
    self.slug = slug
    self.replaced = replaced
  }
}

public enum SkillHubError: LocalizedError, Equatable, Sendable {
  case invalidPath
  case invalidManifest(String)
  case invalidName(String)
  case sizeLimitExceeded
  case readOnlySource
  case skillNotFound
  case variantNotFound
  case customDirectoryAlreadyExists
  case operationFailed(String)

  public var errorDescription: String? {
    switch self {
    case .invalidPath:
      return "技能或目录路径无效。"
    case .invalidManifest(let detail):
      return detail
    case .invalidName(let detail):
      return detail
    case .sizeLimitExceeded:
      return "技能文件过多或过大（上限 2000 个文件、50 MB）。"
    case .readOnlySource:
      return "外部 Agent 目录为只读来源，仅可在 Bridge 自管库中修改或删除。"
    case .skillNotFound:
      return "找不到指定的技能。"
    case .variantNotFound:
      return "找不到指定的技能版本。"
    case .customDirectoryAlreadyExists:
      return "该自定义技能目录已存在。"
    case .operationFailed(let detail):
      return detail
    }
  }
}
