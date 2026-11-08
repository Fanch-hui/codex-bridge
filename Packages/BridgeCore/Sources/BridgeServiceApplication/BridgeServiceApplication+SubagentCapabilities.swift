import BridgeAgentCore
import BridgeDomain
import BridgeMCP
import BridgeServiceCore

extension BridgeServiceApplication {
  public func canSteerSubagent(_ task: MCPServiceTaskSnapshot) async -> Bool {
    guard
      task.status == ServiceTaskStatus.running.rawValue
        || (task.providerID != serviceCodexProviderID
          && task.status == ServiceTaskStatus.waitingForCodexApproval.rawValue),
      let runID = task.turnID ?? task.providerRunID
    else { return false }
    if let providerID = task.providerID, providerID != serviceCodexProviderID {
      guard
        ServiceAgentProviderPolicyRegistry.policy(for: AgentProviderID(rawValue: providerID))?
          .supportsSteer == true
      else { return false }
    }
    return await coordinator.canSteerSubagent(taskID: TaskID(rawValue: task.taskID), runID: runID)
  }
}
