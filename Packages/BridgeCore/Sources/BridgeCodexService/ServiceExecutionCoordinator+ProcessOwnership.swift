import BridgeAgentCore
import BridgeDomain
import BridgeProcess
import Foundation

extension ServiceExecutionCoordinator {
  func withProcessOwnership<T: Sendable>(
    taskID: TaskID, operation: @Sendable () async throws -> T
  ) async throws -> T {
    guard let processOwnershipDirectory, try await tasks.isEmbeddedDSHTask(taskID) else {
      return try await operation()
    }
    if try await tasks.task(id: taskID)?.providerID
      == AgentProviderID.deepSeekHarnessDesktop.rawValue
    {
      return try await operation()
    }
    let scope = try ManagedProcessOwnershipScope(
      directory: processOwnershipDirectory, ownerID: taskID.rawValue)
    return try await ManagedProcessOwnership.$current.withValue(scope) {
      try await operation()
    }
  }

  func confirmOwnedProcessesStopped(taskID: TaskID) async -> Bool {
    guard let processOwnershipDirectory else { return true }
    if let pending = ownedProcessReconciliations[taskID] { return await pending.value }
    do {
      guard try await tasks.isEmbeddedDSHTask(taskID) else { return true }
      if try await tasks.task(id: taskID)?.providerID
        == AgentProviderID.deepSeekHarnessDesktop.rawValue
      {
        return true
      }
      if let pending = ownedProcessReconciliations[taskID] { return await pending.value }
      let scope = try ManagedProcessOwnershipScope(
        directory: processOwnershipDirectory, ownerID: taskID.rawValue)
      let pending = Task.detached(priority: .utility) { scope.recover() }
      ownedProcessReconciliations[taskID] = pending
      let stopped = await pending.value
      ownedProcessReconciliations.removeValue(forKey: taskID)
      guard stopped else {
        _ = try? await tasks.markEmbeddedDSHProcessUnknown(taskID: taskID)
        return false
      }
      return true
    } catch {
      _ = try? await tasks.markEmbeddedDSHProcessUnknown(taskID: taskID)
      return false
    }
  }
}
