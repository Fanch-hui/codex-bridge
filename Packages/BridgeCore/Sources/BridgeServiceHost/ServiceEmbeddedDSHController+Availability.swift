import BridgeACP
import BridgeEmbeddedDSH
import BridgeIPC
import BridgeServiceCore
import Foundation

enum WorkbenchAvailabilityError: Error, Equatable {
  case busy
  case disabled
}

extension ServiceEmbeddedDSHController {
  public func workbenchSettings() async throws -> IPCWorkbenchSettings {
    IPCWorkbenchSettings(enabled: try await settings.workbenchEnabled())
  }

  public func setWorkbenchEnabled(_ enabled: Bool) async throws -> IPCWorkbenchSettings {
    guard !isShuttingDown else { throw CancellationError() }
    guard !isChangingWorkbenchEnabled else { throw WorkbenchAvailabilityError.busy }
    guard enabled || activeMutationRequests == 0 else { throw WorkbenchAvailabilityError.busy }
    isChangingWorkbenchEnabled = true
    workbenchAvailabilityGeneration &+= 1
    eventSignal.notify()
    defer { isChangingWorkbenchEnabled = false }

    let current = try await settings.workbenchEnabled()
    guard current != enabled else { return IPCWorkbenchSettings(enabled: current) }
    if !enabled {
      try await ensureWorkbenchIdle()
      try await stopWorkbenchRuntime()
    }
    try await settings.setWorkbenchEnabled(enabled)
    if enabled, try await settings.applicationMode() == .full {
      resumeWorkbenchRecovery()
    }
    return IPCWorkbenchSettings(enabled: enabled)
  }

  func requireWorkbenchEnabled() async throws {
    guard !isShuttingDown else { throw CancellationError() }
    guard !isChangingWorkbenchEnabled else { throw WorkbenchAvailabilityError.busy }
    let generation = workbenchAvailabilityGeneration
    let enabled = try await settings.workbenchEnabled()
    let mode = try await settings.applicationMode()
    guard !isChangingWorkbenchEnabled, generation == workbenchAvailabilityGeneration else {
      throw WorkbenchAvailabilityError.busy
    }
    guard enabled, mode == .full else { throw WorkbenchAvailabilityError.disabled }
  }

  public func enterLightweightMode() async throws {
    guard !isShuttingDown else { throw CancellationError() }
    guard !isChangingWorkbenchEnabled else { throw WorkbenchAvailabilityError.busy }
    isChangingWorkbenchEnabled = true
    workbenchAvailabilityGeneration &+= 1
    eventSignal.notify()
    defer { isChangingWorkbenchEnabled = false }

    try await ensureWorkbenchIdle()
    try Task.checkCancellation()
    try await stopWorkbenchRuntime()
    try Task.checkCancellation()
    try await settings.setApplicationMode(.lite)
  }

  public func exitLightweightMode() async throws {
    guard !isShuttingDown else { throw CancellationError() }
    guard !isChangingWorkbenchEnabled else { throw WorkbenchAvailabilityError.busy }
    isChangingWorkbenchEnabled = true
    workbenchAvailabilityGeneration &+= 1
    eventSignal.notify()
    defer { isChangingWorkbenchEnabled = false }

    try await settings.setApplicationMode(.full)
  }

  public func resumeWorkbenchRecovery() {
    Task { await self.startNativeWriteRecovery() }
    startExecutionRecovery()
    startSubagentScheduler()
  }

  private func stopWorkbenchRuntime() async throws {
    resetPendingCommunityProviderRefresh()
    operationsRestoreTask?.cancel()
    await subagentScheduler?.shutdown()
    subagentScheduler = nil
    let engine = try engine()
    await engine.shutdown()
    await toolWriteLeases.closeAll()
    guard await engine.confirmedStopped() else {
      throw EmbeddedDSHRuntimeError.processTreeStillRunning
    }
    resetNativeClient()
    runtime = nil
    await communityGateway?.closeWorkbenchGateway()
    recovery = nil
    workspaceMergeMonitor?.cancel()
    workspaceMergeMonitor = nil
  }

  func ensureWorkbenchIdle() async throws {
    let drainDeadline = ContinuousClock.now.advanced(by: .seconds(2))
    while activeWorkbenchRequests > 0 || activeRuntimeInvocations > 0,
      activeMutationRequests == 0, ContinuousClock.now < drainDeadline
    {
      try await Task.sleep(for: .milliseconds(30))
    }
    guard activeWorkbenchRequests == 0, activeRuntimeInvocations == 0,
      activeMutationRequests == 0, !isApplyingConfiguration, idleApplyTask == nil,
      operationTasks.isEmpty, nativeWriteRecoveryTask == nil, executionRecoveryTask == nil,
      bindingTasks.isEmpty, workspaceMergeTasks.isEmpty
    else { throw WorkbenchAvailabilityError.busy }

    // Execution admission holds this gate while registering an owned workspace lease.
    await inputGate.acquire()
    defer { inputGate.release() }
    guard try await application.embeddedDSHExecutions().isEmpty,
      await application.activeUnscopedWorkbenchSessionIDs().isEmpty,
      await application.activeWorkbenchMaintenanceOperationIDs().isEmpty,
      try await store.workbenchOperations(unresolvedOnly: true, limit: 1).isEmpty,
      try await store.pendingWorkbenchProjectBindings().isEmpty,
      try await pendingWorkspaces(includeValidationRequired: true).isEmpty,
      try !hasPersistedNativeWorkspaceWriters(),
      workspaceMergeTasks.isEmpty
    else { throw WorkbenchAvailabilityError.busy }

    if let runtime {
      if let configuration = try await runtime.callIfRunning(action: "configuration.status") {
        guard configuration["activePluginInstalls"]?.intValue == 0,
          configuration["plugins"]?["status"]?.stringValue != "applying"
        else { throw WorkbenchAvailabilityError.busy }
      }
      if let pending = try await runtime.callIfRunning(action: "pending.list") {
        guard let items = pending["items"]?.arrayValue, items.isEmpty else {
          throw WorkbenchAvailabilityError.busy
        }
      }
    }
  }
}
