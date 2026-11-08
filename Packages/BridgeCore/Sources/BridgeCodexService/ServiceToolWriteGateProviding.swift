import BridgeAgentCore
import BridgeDomain
import BridgeServiceCore

/// Supplies per-tool project write admission for tasks that share the project directory with
/// other writers, so they queue around individual writes instead of holding the lease all task.
public protocol ServiceToolWriteGateProviding: Sendable {
  /// The gate for a workbench child task, or nil when the task keeps its whole-task write lease.
  func toolWriteGate(
    for task: ServiceTaskRecord, identity: EmbeddedDSHSubagentIdentity
  ) async throws -> AgentToolWriteGate?

  /// Releases every tool lease the task still holds once none of its processes can be writing.
  func releaseToolWriteLeases(taskID: TaskID) async
}
