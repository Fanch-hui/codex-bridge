import BridgeAgentCore
import BridgeServiceCore

extension ServiceExecutionCoordinator {
  /// Late-bound because the provider is assembled after the coordinator.
  public func setToolWriteGateProvider(_ provider: (any ServiceToolWriteGateProviding)?) {
    toolWriteGateProvider = provider
  }

  func toolWriteGate(for task: ServiceTaskRecord) async throws -> AgentToolWriteGate? {
    guard let provider = toolWriteGateProvider,
      let identity = try await tasks.embeddedDSHSubagentIdentity(taskID: task.id)
    else { return nil }
    return try await provider.toolWriteGate(for: task, identity: identity)
  }
}
