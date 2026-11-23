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

  func bootSubagentScheduler() async {
    do {
      try await requireWorkbenchEnabled()
      if subagentScheduler == nil, try await store.rootsWithOpenSubagentRounds().isEmpty { return }
      _ = try await ensureSubagentScheduler(engineRunning: false)
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
  /// request from a running adapter can also activate the scheduler. The startup import is
  /// allowed to record rounds before the engine can answer calls.
  func ensureSubagentScheduler(engineRunning: Bool = true) async throws -> SubagentRoundScheduler {
    try await requireWorkbenchEnabled()
    let adapterAvailable = engineRunning || runtimeStarted
    let scheduler = subagentScheduler ?? makeSubagentScheduler(engineRunning: adapterAvailable)
    subagentScheduler = scheduler
    if adapterAvailable { await scheduler.adapterStarted() }
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
