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
    try Task.checkCancellation()
    let generation = modelCatalogGenerations[installationID, default: 0]
    guard let stored = try await store.agentInstallation(id: installationID) else {
      throw ServiceStoreError.unknownAgentInstallation(installationID)
    }
    var runtimeBinding = runtimeBinding
    if runtimeBinding == nil { runtimeBinding = try await selectedRuntimeBinding(for: stored) }
    try Task.checkCancellation()
    guard generation == modelCatalogGenerations[installationID, default: 0] else {
      throw CancellationError()
    }
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
        key: storedKey, models: cached, runtimeBinding: runtimeBinding,
        resolveInputModalities: stored.providerID == .deepSeekHarness
          && runtimeBinding?.connectionMode != .nativeDesktop)
    }

    let record = try await validateForRuntimeBinding(
      installationID: installationID,
      projectRoot: projectRoot, runtimeBinding: runtimeBinding)
    try await validateModelCatalogSnapshot(record)
    if generation != modelCatalogGenerations[installationID, default: 0] {
      // Execution validation may refresh an installation's runtime before its first catalog read.
      guard runtimeBinding == nil,
        modelCatalogFingerprint(for: record, runtimeBinding: nil) != storedKey.fingerprint
      else { throw CancellationError() }
    }
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
      key: key, models: models, runtimeBinding: runtimeBinding,
      resolveInputModalities: record.providerID == .deepSeekHarness
        && runtimeBinding?.connectionMode != .nativeDesktop)
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
    try await sharedModelCatalogQuery(key: key, selectedModelID: nil) {
      let fetched = try await self.providerModels(
        record: record, projectRoot: projectRoot, selectedModelID: nil,
        runtimeBinding: runtimeBinding)
      try await self.validateModelCatalogSnapshot(record)
      return await self.mergeModelDescriptors([], fetched)
    }
  }

  private func resolveSelectedModel(
    installationID: AgentInstallationID,
    projectRoot: String?,
    selectedModelID: String?,
    requireSelectedModel: Bool,
    key: ServiceAgentModelCatalogCacheKey,
    models: [AgentModelDescriptor],
    runtimeBinding: AgentRuntimeBinding?,
    resolveInputModalities: Bool
  ) async throws -> [AgentModelDescriptor] {
    try Task.checkCancellation()
    guard let selectedModelID else { return models }
    let selected = AgentModelMatcher.match(selectedModelID, in: models)
    guard
      selected?.reasoningCapabilitiesAvailable == false
        || (selected == nil && requireSelectedModel)
        || (resolveInputModalities && selected?.inputModalities == nil)
    else { return models }
    let generation = modelCatalogGenerations[installationID, default: 0]
    let record = try await validateForRuntimeBinding(
      installationID: installationID,
      projectRoot: projectRoot, runtimeBinding: runtimeBinding)
    guard generation == modelCatalogGenerations[installationID, default: 0],
      modelCatalogFingerprint(for: record, runtimeBinding: runtimeBinding) == key.fingerprint
    else {
      throw CancellationError()
    }
    let merged = try await sharedModelCatalogQuery(
      key: key, selectedModelID: selected?.id ?? selectedModelID
    ) {
      let resolved = try await self.fetchSelectedModelDescriptors(
        record: record, projectRoot: projectRoot, selectedModelID: selected?.id ?? selectedModelID,
        into: models, runtimeBinding: runtimeBinding,
        preserveDefault: resolveInputModalities,
        propagateErrors: resolveInputModalities && selected?.inputModalities == nil)
      try await self.validateModelCatalogSnapshot(record)
      return resolved
    }
    return requireSelectedModel ? try requireModel(selectedModelID, in: merged) : merged
  }

  private func fetchSelectedModelDescriptors(
    record: ServiceAgentInstallationRecord,
    projectRoot: String?,
    selectedModelID: String,
    into cached: [AgentModelDescriptor],
    runtimeBinding: AgentRuntimeBinding?,
    preserveDefault: Bool,
    propagateErrors: Bool
  ) async throws -> [AgentModelDescriptor] {
    do {
      let fetched = try await providerModels(
        record: record,
        projectRoot: projectRoot,
        selectedModelID: selectedModelID,
        runtimeBinding: runtimeBinding
      )
      guard let selected = AgentModelMatcher.match(selectedModelID, in: fetched) else {
        return []
      }
      if preserveDefault {
        let previous = AgentModelMatcher.match(selectedModelID, in: cached)
        let resolved = try AgentModelDescriptor(
          id: selected.id, displayName: selected.displayName,
          compatibleModelIDs: selected.compatibleModelIDs,
          supportedReasoningEfforts: selected.supportedReasoningEfforts,
          defaultReasoningEffort: selected.defaultReasoningEffort,
          reasoningCapabilitiesAvailable: selected.reasoningCapabilitiesAvailable,
          isDefaultModel: previous?.isDefaultModel,
          contextWindowTokens: selected.contextWindowTokens,
          inputModalities: selected.inputModalities)
        return [resolved]
      }
      return [selected]
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      if propagateErrors { throw error }
      return []
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

  private func validateModelCatalogSnapshot(
    _ record: ServiceAgentInstallationRecord
  ) async throws {
    guard let current = try await store.agentInstallation(id: record.id),
      current.isEnabled, current.executableIdentity == record.executableIdentity,
      current.trustProfile == record.trustProfile,
      current.securityProfileID == record.securityProfileID,
      current.artifacts == record.artifacts, current.runtimeArtifacts == record.runtimeArtifacts,
      current.adapterRevision == record.adapterRevision, current.lastProbedAt == record.lastProbedAt
    else { throw CancellationError() }
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

  func mergeModelDescriptors(
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
    return
      (try? AgentModelDescriptor(
        id: incoming.id,
        displayName: incoming.displayName,
        compatibleModelIDs: incoming.compatibleModelIDs,
        supportedReasoningEfforts: incoming.supportedReasoningEfforts,
        defaultReasoningEffort: incoming.defaultReasoningEffort,
        reasoningCapabilitiesAvailable: incoming.reasoningCapabilitiesAvailable,
        isDefaultModel: incoming.isDefaultModel ?? existing.isDefaultModel,
        contextWindowTokens: incoming.contextWindowTokens,
        inputModalities: incoming.inputModalities ?? existing.inputModalities
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
