import BridgeACP
import BridgeAgentCore
import BridgeEmbeddedDSH
import BridgeProcess
import BridgeServiceCore
import Foundation

extension ServiceEmbeddedDSHController {
  func recoverExecutions() async throws {
    let executions = try await application.embeddedDSHExecutions()
    for execution in executions {
      let children = try await application.embeddedDSHSubagents(
        parentSessionID: execution.sessionID)
      for child in children where child.currentStatus == .unknown {
        do {
          try await recoverChild(child)
        } catch {
          await receive(
            EmbeddedDSHEvent(
              sessionID: execution.sessionID, type: "recovery.pending",
              payload: .object([
                "childID": .string(child.childID),
                "message": .string("原 Agent 执行尚待核对，请恢复连接后重试。"),
              ])))
        }
      }
      if execution.rootActive {
        try await application.finishEmbeddedDSHExecution(
          sessionID: execution.sessionID, projectID: execution.projectID)
      }
    }
  }

  func recoverChild(_ child: EmbeddedDSHSubagentBinding) async throws {
    guard child.currentStatus == .unknown, let taskID = child.currentTaskID else { return }
    if child.providerID == AgentProviderID.deepSeekHarnessDesktop.rawValue {
      guard let outcome = try await externalChildRecovery(child) else {
        throw EmbeddedDSHRecoveryError.pendingProcessReconciliation(taskID: taskID)
      }
      _ = try await application.reconcileEmbeddedDSHSubagent(
        parentSessionID: child.parentSessionID, childID: child.childID,
        taskID: taskID, outcome: outcome)
      return
    }
    let scope = try ManagedProcessOwnershipScope(
      directory: dataRoot.appendingPathComponent("AgentProcesses", isDirectory: true),
      ownerID: taskID.rawValue)
    guard await Task.detached(priority: .utility, operation: { scope.recover() }).value else {
      throw EmbeddedDSHRecoveryError.pendingProcessReconciliation(taskID: taskID)
    }
    _ = try await application.confirmEmbeddedDSHSubagentProcessExited(
      parentSessionID: child.parentSessionID, childID: child.childID, taskID: taskID)
  }
}
