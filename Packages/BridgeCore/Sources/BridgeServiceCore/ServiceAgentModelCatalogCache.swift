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
    requireSelectedModel: Bool = true
  ) async throws -> [AgentModelDescriptor] {
    guard let stored = try await store.agentInstallation(id: installationID) else {
      throw ServiceStoreError.unknownAgentInstallation(installationID)
    }
    guard stored.isSelectable else {
      if stored.availability == .needsReview {
        throw ServiceAgentRegistryError.installationNeedsReview(installationID)
      }
      throw ServiceAgentRegistryError.installationUnavailable(installationID)
    }

    let storedKey = ServiceAgentModelCatalogCacheKey(
      installationID: installationID,
      projectRoot: projectRoot,
      fingerprint: modelCatalogFingerprint(for: stored)
    )
    if !forceRefresh,
      let cached = modelCatalogCache[storedKey],
      now().timeIntervalSince(cached.createdAt) < Self.modelCatalogCacheTTL
    {
      if let selectedModelID,
        let selected = cached.models.first(where: { $0.id == selectedModelID }),
        !selected.reasoningCapabilitiesAvailable
      {
        return try await resolveMissingModel(
          installationID: installationID,
          projectRoot: projectRoot,
          selectedModelID: selectedModelID,
          key: storedKey,
          cached: cached.models
        )
      }
      if selectedModelID == nil || cached.models.contains(where: { $0.id == selectedModelID }) {
        return cached.models
      }
      if !requireSelectedModel {
        return cached.models
      }
    }

    let record = try await validateForExecution(installationID: installationID)
    let key = ServiceAgentModelCatalogCacheKey(
      installationID: installationID,
      projectRoot: projectRoot,
      fingerprint: modelCatalogFingerprint(for: record)
    )
    if !forceRefresh,
      let cached = modelCatalogCache[key],
      now().timeIntervalSince(cached.createdAt) < Self.modelCatalogCacheTTL
    {
      if let selectedModelID,
        let selected = cached.models.first(where: { $0.id == selectedModelID }),
        !selected.reasoningCapabilitiesAvailable
      {
        return try await resolveMissingModel(
          installationID: installationID,
          projectRoot: projectRoot,
          selectedModelID: selectedModelID,
          key: key,
          cached: cached.models
        )
      }
      if selectedModelID == nil || cached.models.contains(where: { $0.id == selectedModelID }) {
        return cached.models
      }
      if !requireSelectedModel {
        return cached.models
      }
    }

    if let task = modelCatalogInFlight[key] {
      let models = try await task.value
      if requireSelectedModel {
        return try selectedModelID.map { try requireModel($0, in: models) } ?? models
      }
      return models
    }

    modelCatalogCache.removeValue(forKey: key)
    let task = Task { [self] in
      try await fetchAndCacheModelCatalog(
        record: record,
        projectRoot: projectRoot,
        selectedModelID: selectedModelID,
        key: key,
        requireSelectedModel: requireSelectedModel
      )
    }
    modelCatalogInFlight[key] = task
    defer { modelCatalogInFlight.removeValue(forKey: key) }
    return try await task.value
  }

  private func fetchAndCacheModelCatalog(
    record: ServiceAgentInstallationRecord,
    projectRoot: String?,
    selectedModelID: String?,
    key: ServiceAgentModelCatalogCacheKey,
    requireSelectedModel: Bool
  ) async throws -> [AgentModelDescriptor] {
    let fetched = try await providerModels(
      record: record,
      projectRoot: projectRoot,
      selectedModelID: nil
    )
    var models = mergeModelDescriptors([], fetched)
    if requireSelectedModel, let selectedModelID,
      let selected = models.first(where: { $0.id == selectedModelID }),
      !selected.reasoningCapabilitiesAvailable
    {
      models = try await fetchAndMergeSelectedModel(
        record: record,
        projectRoot: projectRoot,
        selectedModelID: selectedModelID,
        into: models
      )
    } else if requireSelectedModel, let selectedModelID,
      !models.contains(where: { $0.id == selectedModelID })
    {
      models = try await fetchAndMergeSelectedModel(
        record: record,
        projectRoot: projectRoot,
        selectedModelID: selectedModelID,
        into: models
      )
    }
    modelCatalogCache[key] = ServiceAgentModelCatalogCacheEntry(models: models, createdAt: now())
    if requireSelectedModel {
      return try selectedModelID.map { try requireModel($0, in: models) } ?? models
    }
    return models
  }

  private func resolveMissingModel(
    installationID: AgentInstallationID,
    projectRoot: String?,
    selectedModelID: String,
    key: ServiceAgentModelCatalogCacheKey,
    cached: [AgentModelDescriptor]
  ) async throws -> [AgentModelDescriptor] {
    if let task = modelCatalogInFlight[key] {
      let models = try await task.value
      return try requireModel(selectedModelID, in: models)
    }
    let record = try await validateForExecution(installationID: installationID)
    let task = Task { [self] in
      let models = try await fetchAndMergeSelectedModel(
        record: record,
        projectRoot: projectRoot,
        selectedModelID: selectedModelID,
        into: cached
      )
      modelCatalogCache[key] = ServiceAgentModelCatalogCacheEntry(models: models, createdAt: now())
      return models
    }
    modelCatalogInFlight[key] = task
    defer { modelCatalogInFlight.removeValue(forKey: key) }
    return try requireModel(selectedModelID, in: await task.value)
  }

  private func fetchAndMergeSelectedModel(
    record: ServiceAgentInstallationRecord,
    projectRoot: String?,
    selectedModelID: String,
    into cached: [AgentModelDescriptor]
  ) async throws -> [AgentModelDescriptor] {
    do {
      let fetched = try await providerModels(
        record: record,
        projectRoot: projectRoot,
        selectedModelID: selectedModelID
      )
      return mergeModelDescriptors(cached, fetched)
    } catch {
      return cached
    }
  }

  private func providerModels(
    record: ServiceAgentInstallationRecord,
    projectRoot: String?,
    selectedModelID: String?
  ) async throws -> [AgentModelDescriptor] {
    let provider = try provider(for: record.providerID)
    return try await provider.models(
      installation: try record.agentInstallation(),
      projectRoot: projectRoot,
      selectedModelID: selectedModelID
    )
  }

  private func requireModel(
    _ modelID: String,
    in models: [AgentModelDescriptor]
  ) throws -> [AgentModelDescriptor] {
    guard models.contains(where: { $0.id == modelID }) else {
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
        supportedReasoningEfforts: incoming.supportedReasoningEfforts,
        defaultReasoningEffort: incoming.defaultReasoningEffort,
        reasoningCapabilitiesAvailable: incoming.reasoningCapabilitiesAvailable,
        isDefaultModel: existingDefault,
        contextWindowTokens: incoming.contextWindowTokens,
        inputModalities: incoming.inputModalities
      )) ?? incoming
  }

  private func modelCatalogFingerprint(for record: ServiceAgentInstallationRecord) -> String {
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
      record.providerID.rawValue,
      String(record.adapterRevision),
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
