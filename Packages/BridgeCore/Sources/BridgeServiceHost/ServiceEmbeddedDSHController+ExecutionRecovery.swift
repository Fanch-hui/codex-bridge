import BridgeACP
import BridgeEmbeddedDSH
import Foundation

extension ServiceEmbeddedDSHController {
  /// The single recovery of what a previous service run left behind. The first engine call and
  /// the proactive start share it, so it never runs twice. A failed attempt stays failed until
  /// the engine is restarted or the workbench is switched off and on.
  func startedRecovery(engine: EmbeddedDSHRuntime) -> Task<Void, Error> {
    if let recovery { return recovery }
    let task = Task {
      guard await engine.recoverPreviousHost() else {
        throw EmbeddedDSHRuntimeError.transportClosed
      }
      try await self.recoverExecutions()
      try await self.loadConversationMappings()
    }
    recovery = task
    return task
  }

  /// The engine can serve callbacks again after its readiness handshake.
  func workbenchEngineStarted() async {
    guard !isShuttingDown, !runtimeStarted else { return }
    runtimeStarted = true
    if let runtime { flushPendingCommunityProviderRefreshIfNeeded(for: runtime) }
    operationsRestoreTask = Task {
      await self.restoreOperations()
    }
    await bootSubagentScheduler()
  }

  /// Settles executions and children a previous run left behind, without waiting for the
  /// workbench to be opened: an unconfirmed child holds its project's execution group, which
  /// keeps every other writer out. Returns at once; the work runs in the background.
  ///
  /// This only reconciles recorded state (the previous host's process tree and the children's
  /// processes) and never starts the engine. It does nothing while the workbench is switched off
  /// and when there is nothing to recover.
  func startExecutionRecovery() {
    guard executionRecoveryTask == nil, !isShuttingDown else { return }
    executionRecoveryTask = Task {
      defer { self.executionRecoveryTask = nil }
      do {
        try await self.recoverLeftoverExecutions()
      } catch is CancellationError {
        return
      } catch WorkbenchAvailabilityError.disabled {
        return
      } catch WorkbenchAvailabilityError.busy {
        return
      } catch {
        await self.receive(
          EmbeddedDSHEvent(
            type: "recovery.pending",
            payload: .object(["message": .string("工作台恢复尚未完成，请在工作台检查状态。")])))
      }
    }
  }

  private func recoverLeftoverExecutions() async throws {
    try await requireWorkbenchEnabled()
    guard recovery == nil else { return }
    guard try await application.embeddedDSHExecutions().isEmpty == false else { return }
    // Counted like an engine call, so switching the workbench off waits for it.
    activeRuntimeInvocations += 1
    defer { activeRuntimeInvocations -= 1 }
    try await startedRecovery(engine: engine()).value
  }
}
