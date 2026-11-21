import BridgeAgentCore
import BridgeSecurity
import BridgeServiceCore
import BridgeSkills
import Foundation

extension ServiceSkillHub {
  public func handleAction(
    _ action: String,
    payloadData: Data,
    resolveProject: @Sendable (String) async throws -> URL
  ) async throws -> Data {
    try await ensureInitialized()
    let rawObject =
      (try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]) ?? [:]
    let projectID = Self.nonEmptyString(rawObject["projectID"])
    let projectRoot: URL? =
      if let projectID {
        try await resolveProject(projectID)
      } else {
        nil
      }

    switch action {
    case "snapshot":
      let refresh = (rawObject["refresh"] as? Bool) == true
      let snap = try await snapshot(
        projectRoot: projectRoot, projectID: projectID, forceRefresh: refresh)
      return try Self.encodeJSON(snap)

    case "preview":
      let slug = try Self.requiredString(rawObject["slug"], field: "slug")
      let occurrenceID = Self.nonEmptyString(rawObject["occurrenceID"])
      let result = try await preview(
        slug: slug, occurrenceID: occurrenceID, projectRoot: projectRoot, projectID: projectID)
      return try Self.encodeJSON(result)

    case "diff":
      let slug = try Self.requiredString(rawObject["slug"], field: "slug")
      let leftID = Self.nonEmptyString(rawObject["leftOccurrenceID"])
      let rightID = Self.nonEmptyString(rawObject["rightOccurrenceID"])
      let result = try await diff(
        slug: slug, leftID: leftID, rightID: rightID, projectRoot: projectRoot,
        projectID: projectID)
      return try Self.encodeJSON(result)

    case "setSourceEnabled":
      let sourceID = try Self.requiredString(rawObject["sourceID"], field: "sourceID")
      guard let enabled = rawObject["enabled"] as? Bool else {
        throw ServiceStoreError.invalidArgument("skill_hub.enabled")
      }
      return try await setSourceEnabled(
        sourceID: sourceID, enabled: enabled, projectRoot: projectRoot, projectID: projectID)

    case "setSourceOrder":
      guard let order = rawObject["sourceOrder"] as? [String], !order.isEmpty else {
        throw ServiceStoreError.invalidArgument("skill_hub.sourceOrder")
      }
      return try await setSourceOrder(order, projectRoot: projectRoot, projectID: projectID)

    case "addCustomDirectory":
      let path = try Self.requiredString(rawObject["path"], field: "path")
      let name = Self.nonEmptyString(rawObject["name"])
      return try await addCustomDirectory(
        path: path, name: name, projectRoot: projectRoot, projectID: projectID)

    case "removeCustomDirectory":
      let id = try Self.requiredString(rawObject["id"], field: "id")
      return try await removeCustomDirectory(
        id: id, projectRoot: projectRoot, projectID: projectID)

    case "setSkillMode":
      let slug = try Self.requiredString(rawObject["slug"], field: "slug")
      let modeRaw = try Self.requiredString(rawObject["mode"], field: "mode")
      guard let mode = SkillInvocationMode(rawValue: modeRaw) else {
        throw ServiceStoreError.invalidArgument("skill_hub.mode")
      }
      let scopeProjectID = Self.nonEmptyString(rawObject["scopeProjectID"])
      return try await setSkillMode(
        slug: slug, mode: mode, scopeProjectID: scopeProjectID,
        projectRoot: projectRoot, projectID: projectID)

    case "clearProjectOverride":
      let slug = try Self.requiredString(rawObject["slug"], field: "slug")
      let scopeProjectID = try Self.requiredString(
        rawObject["scopeProjectID"], field: "scopeProjectID")
      return try await clearProjectOverride(
        slug: slug, scopeProjectID: scopeProjectID, projectRoot: projectRoot, projectID: projectID)

    case "pinVariant":
      let slug = try Self.requiredString(rawObject["slug"], field: "slug")
      let occurrenceID = Self.nonEmptyString(rawObject["occurrenceID"])
      return try await pinVariant(
        slug: slug, occurrenceID: occurrenceID, projectRoot: projectRoot, projectID: projectID)

    case "importDirectory":
      let path = try Self.requiredString(rawObject["path"], field: "path")
      return try await importDirectory(
        path: path, projectRoot: projectRoot, projectID: projectID)

    case "forkVariant":
      let slug = try Self.requiredString(rawObject["slug"], field: "slug")
      let occurrenceID = try Self.requiredString(rawObject["occurrenceID"], field: "occurrenceID")
      let newName = try Self.requiredString(rawObject["newName"], field: "newName")
      return try await forkVariant(
        slug: slug, occurrenceID: occurrenceID, newName: newName,
        projectRoot: projectRoot, projectID: projectID)

    case "deleteManagedSkill":
      let canonicalPath = try Self.requiredString(
        rawObject["canonicalPath"], field: "canonicalPath")
      let slug = Self.nonEmptyString(rawObject["slug"])
      return try await deleteManagedSkill(
        canonicalPath: canonicalPath, slug: slug, projectRoot: projectRoot, projectID: projectID)

    case "renameManagedSkill":
      let canonicalPath = try Self.requiredString(
        rawObject["canonicalPath"], field: "canonicalPath")
      let newName = try Self.requiredString(rawObject["newName"], field: "newName")
      let slug = Self.nonEmptyString(rawObject["slug"])
      return try await renameManagedSkill(
        canonicalPath: canonicalPath, slug: slug, newName: newName,
        projectRoot: projectRoot, projectID: projectID)

    default:
      throw ServiceStoreError.invalidArgument("skill_hub.action")
    }
  }

  private struct PreviewResponse: Encodable {
    let slug: String
    let occurrenceID: String
    let filePath: String
    let content: String
    let resourceFiles: [String]
  }

  private struct DiffVariantSide: Encodable {
    let id: String
    let sourceName: String
    let filePath: String
    let content: String
  }

  private struct DiffResponse: Encodable {
    let slug: String
    let left: DiffVariantSide
    let right: DiffVariantSide
  }

  private struct ImportResponse: Encodable {
    let imported: [SkillLibraryImportItem]
    let snapshot: SkillHubCatalogSnapshot
  }

  private struct ForkResponse: Encodable {
    let createdSlug: String
    let snapshot: SkillHubCatalogSnapshot
  }

  private struct RenameResponse: Encodable {
    let renamedSlug: String
    let snapshot: SkillHubCatalogSnapshot
  }

  private struct AddCustomDirectoryResponse: Encodable {
    let added: SkillCustomDirectory
    let snapshot: SkillHubCatalogSnapshot
  }

  private func preview(
    slug: String,
    occurrenceID: String?,
    projectRoot: URL?,
    projectID: String?
  ) async throws -> PreviewResponse {
    let snap = try await snapshot(projectRoot: projectRoot, projectID: projectID)
    guard let skill = snap.skills.first(where: { $0.canonicalSlug == slug }) else {
      throw SkillHubError.skillNotFound
    }
    let target =
      occurrenceID.flatMap { id in
        skill.variants.first(where: { $0.occurrence.id == id })?.occurrence
      } ?? skill.winner
    let doc = try SkillDocumentReader.readOccurrence(
      target, slug: skill.canonicalSlug, subpath: "SKILL.md"
    )
    let safeContent = OutboundContentSecurity.redactedSecrets(
      doc.content, maximumUTF8Bytes: SkillScanner.maximumDocumentBytes)
    return PreviewResponse(
      slug: skill.canonicalSlug,
      occurrenceID: target.id,
      filePath: target.entryFilePath,
      content: safeContent,
      resourceFiles: target.resourceFiles
    )
  }

  private func diff(
    slug: String,
    leftID: String?,
    rightID: String?,
    projectRoot: URL?,
    projectID: String?
  ) async throws -> DiffResponse {
    let snap = try await snapshot(projectRoot: projectRoot, projectID: projectID)
    guard let skill = snap.skills.first(where: { $0.canonicalSlug == slug }) else {
      throw SkillHubError.skillNotFound
    }
    let leftVariant =
      leftID.flatMap { id in skill.variants.first(where: { $0.occurrence.id == id })?.occurrence }
      ?? skill.winner
    let rightVariant =
      rightID.flatMap { id in skill.variants.first(where: { $0.occurrence.id == id })?.occurrence }
      ?? skill.variants.first(where: {
        $0.occurrence.id != leftVariant.id
          && ($0.relation == .conflict || $0.relation == .overriddenByProject)
      })?.occurrence
      ?? skill.variants.first(where: { $0.occurrence.id != leftVariant.id })?.occurrence
    guard let rightVariant else { throw SkillHubError.variantNotFound }

    let leftDoc = try SkillDocumentReader.readOccurrence(leftVariant, slug: slug)
    let rightDoc = try SkillDocumentReader.readOccurrence(rightVariant, slug: slug)
    return DiffResponse(
      slug: slug,
      left: DiffVariantSide(
        id: leftVariant.id,
        sourceName: leftVariant.sourceName,
        filePath: leftVariant.entryFilePath,
        content: OutboundContentSecurity.redactedSecrets(
          leftDoc.content, maximumUTF8Bytes: SkillScanner.maximumDocumentBytes)
      ),
      right: DiffVariantSide(
        id: rightVariant.id,
        sourceName: rightVariant.sourceName,
        filePath: rightVariant.entryFilePath,
        content: OutboundContentSecurity.redactedSecrets(
          rightDoc.content, maximumUTF8Bytes: SkillScanner.maximumDocumentBytes)
      )
    )
  }

  private func setSourceEnabled(
    sourceID: String,
    enabled: Bool,
    projectRoot: URL?,
    projectID: String?
  ) async throws -> Data {
    var policy = cachedPolicy
    if let customIndex = policy.customDirectories.firstIndex(where: { $0.id == sourceID }) {
      policy.customDirectories[customIndex].enabled = enabled
    }
    policy.sourceEnabled[sourceID] = enabled
    try await savePolicyAndInvalidate(policy)
    return try Self.encodeJSON(
      try await snapshot(projectRoot: projectRoot, projectID: projectID, forceRefresh: true))
  }

  private func setSourceOrder(
    _ order: [String],
    projectRoot: URL?,
    projectID: String?
  ) async throws -> Data {
    var policy = cachedPolicy
    policy.sourceOrder = order
    try await savePolicyAndInvalidate(policy)
    return try Self.encodeJSON(
      try await snapshot(projectRoot: projectRoot, projectID: projectID, forceRefresh: true))
  }

  private func addCustomDirectory(
    path: String,
    name: String?,
    projectRoot: URL?,
    projectID: String?
  ) async throws -> Data {
    guard AgentPathSemantics.isAbsolute(path), !path.contains("\0") else {
      throw SkillHubError.invalidPath
    }
    let cleanURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: cleanURL.path, isDirectory: &isDir),
      isDir.boolValue
    else {
      throw SkillHubError.invalidPath
    }
    let managed = libraryStore.rootURL.standardizedFileURL.path
    if cleanURL.path == managed {
      throw SkillHubError.customDirectoryAlreadyExists
    }
    var policy = cachedPolicy
    if policy.customDirectories.contains(where: {
      URL(fileURLWithPath: $0.path, isDirectory: true).standardizedFileURL.path == cleanURL.path
    }) {
      throw SkillHubError.customDirectoryAlreadyExists
    }
    let entry = SkillCustomDirectory(
      id: "custom-\(UUID().uuidString.lowercased())",
      name: name ?? cleanURL.lastPathComponent,
      path: cleanURL.path,
      enabled: true
    )
    policy.customDirectories.append(entry)
    policy.sourceEnabled[entry.id] = true
    try await savePolicyAndInvalidate(policy)
    let snap = try await snapshot(
      projectRoot: projectRoot, projectID: projectID, forceRefresh: true)
    return try Self.encodeJSON(AddCustomDirectoryResponse(added: entry, snapshot: snap))
  }

  private func removeCustomDirectory(
    id: String,
    projectRoot: URL?,
    projectID: String?
  ) async throws -> Data {
    var policy = cachedPolicy
    policy.customDirectories.removeAll { $0.id == id }
    policy.sourceEnabled.removeValue(forKey: id)
    policy.sourceOrder.removeAll { $0 == id }
    try await savePolicyAndInvalidate(policy)
    return try Self.encodeJSON(
      try await snapshot(projectRoot: projectRoot, projectID: projectID, forceRefresh: true))
  }

  private func setSkillMode(
    slug: String,
    mode: SkillInvocationMode,
    scopeProjectID: String?,
    projectRoot: URL?,
    projectID: String?
  ) async throws -> Data {
    var policy = cachedPolicy
    if let scopeProjectID {
      var overrides = policy.projectSkillOverrides[scopeProjectID] ?? [:]
      overrides[slug] = mode
      policy.projectSkillOverrides[scopeProjectID] = overrides
    } else {
      var item = policy.skillPolicies[slug] ?? SkillItemPolicy()
      item.invocationMode = mode
      policy.skillPolicies[slug] = item
    }
    try await savePolicyAndInvalidate(policy)
    return try Self.encodeJSON(
      try await snapshot(projectRoot: projectRoot, projectID: projectID, forceRefresh: true))
  }

  private func clearProjectOverride(
    slug: String,
    scopeProjectID: String,
    projectRoot: URL?,
    projectID: String?
  ) async throws -> Data {
    var policy = cachedPolicy
    policy.projectSkillOverrides[scopeProjectID]?.removeValue(forKey: slug)
    if policy.projectSkillOverrides[scopeProjectID]?.isEmpty == true {
      policy.projectSkillOverrides.removeValue(forKey: scopeProjectID)
    }
    try await savePolicyAndInvalidate(policy)
    return try Self.encodeJSON(
      try await snapshot(projectRoot: projectRoot, projectID: projectID, forceRefresh: true))
  }

  private func pinVariant(
    slug: String,
    occurrenceID: String?,
    projectRoot: URL?,
    projectID: String?
  ) async throws -> Data {
    var policy = cachedPolicy
    var item = policy.skillPolicies[slug] ?? SkillItemPolicy()
    item.pinnedOccurrenceID = occurrenceID
    policy.skillPolicies[slug] = item
    try await savePolicyAndInvalidate(policy)
    return try Self.encodeJSON(
      try await snapshot(projectRoot: projectRoot, projectID: projectID, forceRefresh: true))
  }

  private func importDirectory(
    path: String,
    projectRoot: URL?,
    projectID: String?
  ) async throws -> Data {
    guard AgentPathSemantics.isAbsolute(path), !path.contains("\0") else {
      throw SkillHubError.invalidPath
    }
    let imported = try libraryStore.importFromPath(URL(fileURLWithPath: path))
    await invalidateAndNotify()
    let snap = try await snapshot(
      projectRoot: projectRoot, projectID: projectID, forceRefresh: true)
    return try Self.encodeJSON(ImportResponse(imported: imported, snapshot: snap))
  }

  private func forkVariant(
    slug: String,
    occurrenceID: String,
    newName: String,
    projectRoot: URL?,
    projectID: String?
  ) async throws -> Data {
    let current = try await snapshot(projectRoot: projectRoot, projectID: projectID)
    guard let skill = current.skills.first(where: { $0.canonicalSlug == slug }),
      let occurrence = skill.variants.first(where: { $0.occurrence.id == occurrenceID })?.occurrence
    else {
      throw SkillHubError.variantNotFound
    }
    let createdSlug = try libraryStore.forkOccurrence(occurrence, newName: newName)
    await invalidateAndNotify()
    let snap = try await snapshot(
      projectRoot: projectRoot, projectID: projectID, forceRefresh: true)
    return try Self.encodeJSON(ForkResponse(createdSlug: createdSlug, snapshot: snap))
  }

  private func deleteManagedSkill(
    canonicalPath: String,
    slug: String?,
    projectRoot: URL?,
    projectID: String?
  ) async throws -> Data {
    try libraryStore.deleteManagedSkill(canonicalPath: canonicalPath)
    await invalidateAndNotify()
    let snap = try await snapshot(
      projectRoot: projectRoot, projectID: projectID, forceRefresh: true)
    if let slug, !snap.skills.contains(where: { $0.canonicalSlug == slug }) {
      var policy = cachedPolicy
      policy.skillPolicies.removeValue(forKey: slug)
      for key in Array(policy.projectSkillOverrides.keys) {
        policy.projectSkillOverrides[key]?.removeValue(forKey: slug)
      }
      try await savePolicyAndInvalidate(policy)
      return try Self.encodeJSON(
        try await snapshot(projectRoot: projectRoot, projectID: projectID, forceRefresh: true))
    }
    return try Self.encodeJSON(snap)
  }

  private func renameManagedSkill(
    canonicalPath: String,
    slug: String?,
    newName: String,
    projectRoot: URL?,
    projectID: String?
  ) async throws -> Data {
    let renamedSlug = try libraryStore.renameManagedSkill(
      canonicalPath: canonicalPath, newName: newName)
    await invalidateAndNotify()
    if let slug, slug != renamedSlug, let existing = cachedPolicy.skillPolicies[slug] {
      var policy = cachedPolicy
      let snapBeforePolicy = try await snapshot(
        projectRoot: projectRoot, projectID: projectID, forceRefresh: true)
      if !snapBeforePolicy.skills.contains(where: { $0.canonicalSlug == slug }) {
        policy.skillPolicies.removeValue(forKey: slug)
      }
      if policy.skillPolicies[renamedSlug] == nil {
        policy.skillPolicies[renamedSlug] = existing
      }
      try await savePolicyAndInvalidate(policy)
    }
    let snap = try await snapshot(
      projectRoot: projectRoot, projectID: projectID, forceRefresh: true)
    return try Self.encodeJSON(RenameResponse(renamedSlug: renamedSlug, snapshot: snap))
  }

  private static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }

  private static func requiredString(_ value: Any?, field: String) throws -> String {
    guard let string = nonEmptyString(value) else {
      throw ServiceStoreError.invalidArgument("skill_hub.\(field)")
    }
    return string
  }

  private static func nonEmptyString(_ value: Any?) -> String? {
    guard let raw = value as? String else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
