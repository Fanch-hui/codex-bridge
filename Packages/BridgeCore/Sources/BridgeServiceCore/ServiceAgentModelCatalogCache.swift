import BridgeAgentCore
import Foundation

struct ServiceAgentModelCatalogCacheKey: Hashable, Sendable {
  let installationID: AgentInstallationID
  let projectRoot: String?
  let fingerprint: String
}

struct ServiceAgentModelCatalogCacheEntry: Sendable {
  let models: [AgentModelDescriptor]
  let createdAt: Date
}

extension ServiceAgentRegistry {
  static let modelCatalogCacheTTL: TimeInterval = 5 * 60

  public func models(
    installationID: AgentInstallationID,
    projectRoot: String? = nil,
    selectedModelID: String? = nil,
    forceRefresh: Bool = false,
    requireSelectedModel: Bool = true,
    runtimeBinding: AgentRuntimeBinding? = nil
  ) async throws -> [AgentModelDescriptor] {
    guard let stored = try await store.agentInstallation(id: installationID) else {
      throw ServiceStoreError.unknownAgentInstallation(installationID)
    }
    var runtimeBinding = runtimeBinding
    if runtimeBinding == nil { runtimeBinding = try await selectedRuntimeBinding(for: stored) }
    guard stored.isSelectable || (stored.isEnabled && runtimeBinding != nil) else {
      if stored.availability == .needsReview {
        throw ServiceAgentRegistryError.installationNeedsReview(installationID)
      }
      throw ServiceAgentRegistryError.installationUnavailable(installationID)
    }

    let storedKey = ServiceAgentModelCatalogCacheKey(
      installationID: installationID,
      projectRoot: projectRoot,
      fingerprint: modelCatalogFingerprint(for: stored, runtimeBinding: runtimeBinding)
    )
    if !forceRefresh,
      let cached = freshModelCatalog(for: storedKey)
    {
      return try await resolveSelectedModel(
        installationID: installationID, projectRoot: projectRoot,
        selectedModelID: selectedModelID, requireSelectedModel: requireSelectedModel,
        key: storedKey, models: cached, runtimeBinding: runtimeBinding)
    }

    let record = try await validateForRuntimeBinding(
      installationID: installationID,
      projectRoot: projectRoot, runtimeBinding: runtimeBinding)
    let key = ServiceAgentModelCatalogCacheKey(
      installationID: installationID,
      projectRoot: projectRoot,
      fingerprint: modelCatalogFingerprint(for: record, runtimeBinding: runtimeBinding)
    )
    let models: [AgentModelDescriptor]
    if !forceRefresh, let cached = freshModelCatalog(for: key) {
      models = cached
    } else {
      models = try await sharedModelCatalog(
        record: record, projectRoot: projectRoot, key: key, runtimeBinding: runtimeBinding)
    }
    return try await resolveSelectedModel(
      installationID: installationID, projectRoot: projectRoot,
      selectedModelID: selectedModelID, requireSelectedModel: requireSelectedModel,
      key: key, models: models, runtimeBinding: runtimeBinding)
  }

  private func freshModelCatalog(
    for key: ServiceAgentModelCatalogCacheKey
  ) -> [AgentModelDescriptor]? {
    guard let cached = modelCatalogCache[key],
      now().timeIntervalSince(cached.createdAt) < Self.modelCatalogCacheTTL
    else { return nil }
    return cached.models
  }

  private func sharedModelCatalog(
    record: ServiceAgentInstallationRecord,
    projectRoot: String?,
    key: ServiceAgentModelCatalogCacheKey,
    runtimeBinding: AgentRuntimeBinding?
  ) async throws -> [AgentModelDescriptor] {
    if let task = modelCatalogInFlight[key] { return try await task.value }
    let task = Task { [self] in
      let fetched = try await providerModels(
        record: record, projectRoot: projectRoot, selectedModelID: nil,
        runtimeBinding: runtimeBinding)
      let models = mergeModelDescriptors([], fetched)
      modelCatalogCache[key] = ServiceAgentModelCatalogCacheEntry(models: models, createdAt: now())
      return models
    }
    modelCatalogInFlight[key] = task
    defer { modelCatalogInFlight.removeValue(forKey: key) }
    return try await task.value
  }

  private func resolveSelectedModel(
    installationID: AgentInstallationID,
    projectRoot: String?,
    selectedModelID: String?,
    requireSelectedModel: Bool,
    key: ServiceAgentModelCatalogCacheKey,
    models: [AgentModelDescriptor],
    runtimeBinding: AgentRuntimeBinding?
  ) async throws -> [AgentModelDescriptor] {
    guard let selectedModelID else { return models }
    let selected = AgentModelMatcher.match(selectedModelID, in: models)
    guard
      selected?.reasoningCapabilitiesAvailable == false
        || (selected == nil && requireSelectedModel)
    else { return models }
    let record = try await validateForRuntimeBinding(
      installationID: installationID,
      projectRoot: projectRoot, runtimeBinding: runtimeBinding)
    let resolved = try await fetchAndMergeSelectedModel(
      record: record, projectRoot: projectRoot, selectedModelID: selected?.id ?? selectedModelID,
      into: models, runtimeBinding: runtimeBinding)
    // Another caller may have resolved a different selection during this await.
    let merged = mergeModelDescriptors(modelCatalogCache[key]?.models ?? [], resolved)
    modelCatalogCache[key] = ServiceAgentModelCatalogCacheEntry(models: merged, createdAt: now())
    return requireSelectedModel ? try requireModel(selectedModelID, in: merged) : merged
  }

  private func fetchAndMergeSelectedModel(
    record: ServiceAgentInstallationRecord,
    projectRoot: String?,
    selectedModelID: String,
    into cached: [AgentModelDescriptor],
    runtimeBinding: AgentRuntimeBinding?
  ) async throws -> [AgentModelDescriptor] {
    do {
      let fetched = try await providerModels(
        record: record,
        projectRoot: projectRoot,
        selectedModelID: selectedModelID,
        runtimeBinding: runtimeBinding
      )
      return mergeModelDescriptors(cached, fetched)
    } catch {
      return cached
    }
  }

  private func providerModels(
    record: ServiceAgentInstallationRecord,
    projectRoot: String?,
    selectedModelID: String?,
    runtimeBinding: AgentRuntimeBinding?
  ) async throws -> [AgentModelDescriptor] {
    let provider = try provider(for: record.providerID)
    return try await provider.models(
      installation: try record.agentInstallation(),
      projectRoot: projectRoot,
      selectedModelID: selectedModelID,
      runtimeBinding: runtimeBinding
    )
  }

  private func requireModel(
    _ modelID: String,
    in models: [AgentModelDescriptor]
  ) throws -> [AgentModelDescriptor] {
    guard AgentModelMatcher.match(modelID, in: models) != nil else {
      throw AgentRuntimeError.modelUnavailable(modelID)
    }
    return models
  }

  private func mergeModelDescriptors(
    _ existing: [AgentModelDescriptor],
    _ incoming: [AgentModelDescriptor]
  ) -> [AgentModelDescriptor] {
    var result = existing
    for model in incoming {
      guard let index = result.firstIndex(where: { $0.id == model.id }) else {
        result.append(model)
        continue
      }
      if model.reasoningCapabilitiesAvailable || !result[index].reasoningCapabilitiesAvailable {
        result[index] = mergingDefaultModel(model, with: result[index])
      }
    }
    return result
  }

  private func mergingDefaultModel(
    _ incoming: AgentModelDescriptor,
    with existing: AgentModelDescriptor
  ) -> AgentModelDescriptor {
    guard incoming.isDefaultModel == nil, let existingDefault = existing.isDefaultModel else {
      return incoming
    }
    return
      (try? AgentModelDescriptor(
        id: incoming.id,
        displayName: incoming.displayName,
        compatibleModelIDs: incoming.compatibleModelIDs,
        supportedReasoningEfforts: incoming.supportedReasoningEfforts,
        defaultReasoningEffort: incoming.defaultReasoningEffort,
        reasoningCapabilitiesAvailable: incoming.reasoningCapabilitiesAvailable,
        isDefaultModel: existingDefault,
        contextWindowTokens: incoming.contextWindowTokens,
        inputModalities: incoming.inputModalities
      )) ?? incoming
  }

  private func modelCatalogFingerprint(
    for record: ServiceAgentInstallationRecord,
    runtimeBinding: AgentRuntimeBinding?
  ) -> String {
    let executable = record.executableIdentity
    let artifacts = record.artifacts.map { artifact in
      let identity = artifact.identity
      return [
        artifact.role.rawValue,
        identity.canonicalPath,
        String(identity.device),
        String(identity.inode),
        String(identity.fileSize),
        String(identity.modificationTimeNanoseconds),
        identity.sha256,
      ].joined(separator: ":")
    }.joined(separator: "|")
    return [
      runtimeBinding?.connectionMode.rawValue ?? "",
      runtimeBinding?.profileID ?? "",
      record.providerID.rawValue,
      String(record.adapterRevision),
      record.lastProbedAt.map { String($0.timeIntervalSince1970) } ?? "",
      executable.canonicalPath,
      String(executable.device),
      String(executable.inode),
      String(executable.fileSize),
      String(executable.modificationTimeNanoseconds),
      executable.sha256,
      artifacts,
    ].joined(separator: "\n")
  }
}
