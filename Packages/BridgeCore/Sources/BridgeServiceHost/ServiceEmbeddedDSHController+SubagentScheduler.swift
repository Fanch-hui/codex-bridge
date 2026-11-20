import BridgeACP
import BridgeEmbeddedDSH
import BridgeServiceCore
import Foundation

extension ServiceEmbeddedDSHController {
  /// Resumes the subagent rounds a previous run left open. Returns at once; the work runs in the
  /// background and does nothing while the workbench is off or when no round is open. The
  /// scheduler starts without the engine: it reconciles recorded state in process and leaves
  /// everything that needs the engine until the engine has been started by a user action.
  func startSubagentScheduler() {
    guard !isShuttingDown else { return }
    Task { await self.bootSubagentScheduler() }
  }

  private func bootSubagentScheduler() async {
    do {
      try await requireWorkbenchEnabled()
      guard try await !store.rootsWithOpenSubagentRounds().isEmpty else { return }
      _ = try await ensureSubagentScheduler(engineRunning: operationsRestoreStarted)
    } catch is CancellationError {
      return
    } catch WorkbenchAvailabilityError.disabled {
      return
    } catch WorkbenchAvailabilityError.busy {
      return
    } catch {
      await receive(
        EmbeddedDSHEvent(
          type: "subagent.schedulerFailed",
          payload: .object(["message": .string(Self.subagentErrorText(error))])))
    }
  }

  /// The scheduler, created on first use and started once. Starting recovers open rounds. A
  /// request the engine itself sent (`bridge/subagent`) proves the engine is running, and so does
  /// a recovery that already started it.
  func ensureSubagentScheduler(engineRunning: Bool = true) async throws -> SubagentRoundScheduler {
    try await requireWorkbenchEnabled()
    let scheduler = subagentScheduler ?? makeSubagentScheduler(engineRunning: engineRunning)
    subagentScheduler = scheduler
    if engineRunning { await scheduler.adapterStarted() }
    try await scheduler.start()
    return scheduler
  }

  private func makeSubagentScheduler(engineRunning: Bool) -> SubagentRoundScheduler {
    let ports = EmbeddedDSHSubagentPorts(controller: self)
    return SubagentRoundScheduler(
      ledger: StoreSubagentRoundLedger(store: store), tasks: ports, workspace: ports,
      leases: ports, roots: ports, events: ports,
      configuration: SubagentRoundScheduler.Configuration(adapterAvailable: engineRunning),
      describe: Self.subagentErrorText)
  }

  /// The text of an error as the controlling model reads it: the mapped code and message.
  static func subagentErrorText(_ error: any Error) -> String {
    let underlying = (error as? SubagentTransientError)?.underlying ?? error
    let mapped = BridgeServiceRequestController.map(underlying)
    return "\(mapped.code): \(mapped.message)"
  }
}
