import BridgeAgentCore
import Foundation

struct ServiceAgentModelCatalogQueryKey: Hashable, Sendable {
  let catalog: ServiceAgentModelCatalogCacheKey
  let selectedModelID: String?
}

struct ServiceAgentModelCatalogOperation: Sendable {
  let id: UUID
  let task: Task<Void, Never>
  var waiters: [UUID: CheckedContinuation<[AgentModelDescriptor], Error>]
}

extension ServiceAgentRegistry {
  func sharedModelCatalogQuery(
    key: ServiceAgentModelCatalogCacheKey,
    selectedModelID: String?,
    fetch: @escaping @Sendable () async throws -> [AgentModelDescriptor]
  ) async throws -> [AgentModelDescriptor] {
    try Task.checkCancellation()
    let query = ServiceAgentModelCatalogQueryKey(catalog: key, selectedModelID: selectedModelID)
    let operationID: UUID
    if let current = modelCatalogInFlight[query] {
      operationID = current.id
    } else {
      operationID = UUID()
      let task = Task {
        let result: Result<[AgentModelDescriptor], Error>
        do {
          let models = try await fetch()
          try Task.checkCancellation()
          result = .success(models)
        } catch {
          result = .failure(error)
        }
        finishModelCatalogQuery(query, operationID: operationID, result: result)
      }
      modelCatalogInFlight[query] = ServiceAgentModelCatalogOperation(
        id: operationID, task: task, waiters: [:])
    }
    let waiterID = UUID()
    let models: [AgentModelDescriptor] = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        modelCatalogInFlight[query]?.waiters[waiterID] = continuation
      }
    } onCancel: {
      Task {
        await self.cancelModelCatalogWaiter(query, operationID: operationID, waiterID: waiterID)
      }
    }
    try Task.checkCancellation()
    return models
  }

  private func finishModelCatalogQuery(
    _ query: ServiceAgentModelCatalogQueryKey,
    operationID: UUID,
    result: Result<[AgentModelDescriptor], Error>
  ) {
    guard let current = modelCatalogInFlight[query], current.id == operationID else { return }
    modelCatalogInFlight.removeValue(forKey: query)
    let result = result.map { models in
      let existing = modelCatalogCache[query.catalog]
      let merged =
        query.selectedModelID == nil
        ? models : mergeModelDescriptors(existing?.models ?? [], models)
      modelCatalogCache[query.catalog] = ServiceAgentModelCatalogCacheEntry(
        models: merged,
        createdAt: query.selectedModelID == nil ? now() : existing?.createdAt ?? now())
      return merged
    }
    for waiter in current.waiters.values { waiter.resume(with: result) }
  }

  private func cancelModelCatalogWaiter(
    _ query: ServiceAgentModelCatalogQueryKey, operationID: UUID, waiterID: UUID
  ) {
    guard var current = modelCatalogInFlight[query], current.id == operationID,
      let waiter = current.waiters.removeValue(forKey: waiterID)
    else { return }
    if current.waiters.isEmpty {
      modelCatalogInFlight.removeValue(forKey: query)
      current.task.cancel()
    } else {
      modelCatalogInFlight[query] = current
    }
    waiter.resume(throwing: CancellationError())
  }

  public func invalidateModelCatalog(installationID: AgentInstallationID) {
    modelCatalogGenerations[installationID, default: 0] &+= 1
    modelCatalogCache = modelCatalogCache.filter { $0.key.installationID != installationID }
    let queries = modelCatalogInFlight.keys.filter { $0.catalog.installationID == installationID }
    for query in queries {
      guard let operation = modelCatalogInFlight.removeValue(forKey: query) else { continue }
      operation.task.cancel()
      for waiter in operation.waiters.values { waiter.resume(throwing: CancellationError()) }
    }
  }

  func updateInstallation(
    _ record: ServiceAgentInstallationRecord,
    allowExecutableReplacement: Bool = false,
    expectedRecord: ServiceAgentInstallationRecord? = nil
  ) async throws {
    try await store.updateAgentInstallation(
      record, allowExecutableReplacement: allowExecutableReplacement, expectedRecord: expectedRecord
    )
    invalidateModelCatalog(installationID: record.id)
  }
}
