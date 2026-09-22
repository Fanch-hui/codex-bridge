import BridgeDirectCommand
import BridgeMCP
import BridgeServiceCore
import Foundation

extension BridgeServiceApplication {
  public func serviceStatus(
    deadline: ContinuousClock.Instant
  ) async throws -> BridgeStatusSnapshot {
    try Self.checkDeadline(deadline)
    let taskList = try await tasks.nonterminalTasks()
    let runtime = await runtimeStatus.current()
    let directApprovals = await approvals.pendingApprovals().count
    let codexApprovals = await coordinator.pendingApprovals().count
    let taskStartApprovals = taskList.filter {
      !$0.isQueued
        && $0.state.status == .awaitingLocalApproval
        && $0.requiresLocalStartApproval
    }.count
    let directEnvironment = await directCommands.executionEnvironmentCapabilities()
    var degradations = runtime.degradations
    let activeTasks = taskList.filter { !$0.state.status.isTerminal }
    for task in activeTasks where task.state.supervisorStatus == .degraded {
      let summary =
        task.state.supervisorSummary
        ?? "Supervisor degraded for active task \(task.id.rawValue)"
      if !degradations.contains(summary) {
        degradations.append(summary)
      }
    }
    return BridgeStatusSnapshot(
      appVersion: appVersion,
      mcpState: runtime.mcpState,
      tunnelState: runtime.tunnelState,
      codexVersion: runtime.codexVersion,
      loginMode: runtime.loginMode,
      codexExecutablePath: runtime.codexExecutablePath,
      codexResolvedExecutablePath: runtime.codexResolvedExecutablePath,
      executionState: Self.executionState(taskList),
      supervisorState: Self.supervisorState(taskList),
      degradations: degradations,
      pendingApprovalCount: codexApprovals + taskStartApprovals + directApprovals,
      executionEnvironment: Self.mcpEnvironment(directEnvironment)
    )
  }
}
