import BridgeAgentCore
import BridgeDomain
import BridgeProcess
import Foundation

private enum OwnedProcessKind {
  case embeddedDSH
  case claude
}

extension ServiceExecutionCoordinator {
  private func ownedProcessKind(taskID: TaskID) async throws -> OwnedProcessKind? {
    guard let task = try await tasks.task(id: taskID) else { return nil }
    if try await tasks.isEmbeddedDSHTask(taskID) {
      return task.providerID == AgentProviderID.deepSeekHarnessDesktop.rawValue
        ? nil : .embeddedDSH
    }
    return task.providerID == AgentProviderID.claudeCode.rawValue ? .claude : nil
  }

  func withProcessOwnership<T: Sendable>(
    taskID: TaskID, operation: @Sendable () async throws -> T
  ) async throws -> T {
    guard let kind = try await ownedProcessKind(taskID: taskID) else {
      return try await operation()
    }
    guard let processOwnershipDirectory else {
      if kind == .claude { throw AgentRuntimeError.processUnavailable }
      return try await operation()
    }
    let scope = try ManagedProcessOwnershipScope(
      directory: processOwnershipDirectory, ownerID: taskID.rawValue)
    return try await ManagedProcessOwnership.$current.withValue(scope) {
      try await operation()
    }
  }

  /// Every task end path funnels through here; tool write leases are released only once no
  /// process of the task can still be writing.
  func confirmOwnedProcessesStopped(taskID: TaskID) async -> Bool {
    guard await ownedProcessesStopped(taskID: taskID) else { return false }
    await toolWriteGateProvider?.releaseToolWriteLeases(taskID: taskID)
    return true
  }

  private func ownedProcessesStopped(taskID: TaskID) async -> Bool {
    var kind: OwnedProcessKind?
    do {
      kind = try await ownedProcessKind(taskID: taskID)
      guard let kind else { return true }
      guard let processOwnershipDirectory else {
        if kind == .claude { throw AgentRuntimeError.processUnavailable }
        return true
      }
      let pending: Task<Bool, Never>
      let ownsPending: Bool
      if let existing = ownedProcessReconciliations[taskID] {
        pending = existing
        ownsPending = false
      } else {
        let scope = try ManagedProcessOwnershipScope(
          directory: processOwnershipDirectory, ownerID: taskID.rawValue)
        pending = Task.detached(priority: .utility) { scope.recover() }
        ownedProcessReconciliations[taskID] = pending
        ownsPending = true
      }
      let stopped = await pending.value
      if ownsPending { ownedProcessReconciliations.removeValue(forKey: taskID) }
      guard stopped else {
        await markProcessUnknown(taskID: taskID, kind: kind)
        return false
      }
      if kind == .claude, try await tasks.task(id: taskID)?.state.status == .unknown {
        _ = try await tasks.confirmClaudeProcessStopped(taskID: taskID)
      }
      return true
    } catch {
      if let kind { await markProcessUnknown(taskID: taskID, kind: kind) }
      return false
    }
  }

  private func markProcessUnknown(taskID: TaskID, kind: OwnedProcessKind) async {
    switch kind {
    case .embeddedDSH:
      _ = try? await tasks.markEmbeddedDSHProcessUnknown(taskID: taskID)
    case .claude:
      do {
        if let task = try await tasks.task(id: taskID), task.state.status.isTerminal { return }
        _ = try await tasks.markClaudeProcessUnknown(taskID: taskID)
        startClaudeRecoveryMonitor()
      } catch {
        FileHandle.standardError.write(
          Data("Claude process recovery state could not be saved.\n".utf8))
      }
    }
  }

  /// Reconcile prior Claude processes before dispatching the service task queue.
  public func recoverClaudeProcesses() async throws {
    guard processOwnershipDirectory != nil else { return }
    if try await inspectClaudeProcesses() { startClaudeRecoveryMonitor() }
  }

  private func inspectClaudeProcesses() async throws -> Bool {
    guard let directory = processOwnershipDirectory else { return true }
    let pending = try await tasks.nonterminalTasks().filter {
      $0.providerID == AgentProviderID.claudeCode.rawValue && $0.state.status == .unknown
    }
    var remains = false
    for task in pending {
      if try await tasks.isEmbeddedDSHTask(task.id) { continue }
      let scope = try ManagedProcessOwnershipScope(directory: directory, ownerID: task.id.rawValue)
      let stopped = await Task.detached(priority: .utility) { scope.releaseExited() }.value
      if stopped {
        let current = try await tasks.task(id: task.id)
        if current?.state.status == .unknown {
          _ = try await tasks.confirmClaudeProcessStopped(taskID: task.id)
        }
      } else {
        remains = true
      }
    }
    return remains
  }

  private func startClaudeRecoveryMonitor() {
    claudeRecoveryGeneration &+= 1
    guard !isShuttingDown, claudeRecoveryMonitor == nil else { return }
    claudeRecoveryMonitor = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
        guard let self, !Task.isCancelled else { return }
        if !(await self.retryClaudeProcessRecovery()) { return }
      }
    }
  }

  private func retryClaudeProcessRecovery() async -> Bool {
    let generation = claudeRecoveryGeneration
    do {
      let remains = try await inspectClaudeProcesses()
      if !remains, generation == claudeRecoveryGeneration {
        claudeRecoveryMonitor = nil
        return false
      }
      return true
    } catch {
      claudeRecoveryMonitor = nil
      FileHandle.standardError.write(Data("Claude process recovery check failed.\n".utf8))
      return false
    }
  }
}
